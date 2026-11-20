import Foundation

@main
struct IntegrationCheck {
    enum Failure: Error { case missingFixture, expectedFailure, timedOut }

    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Integration check failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.missingFixture }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        if ProcessInfo.processInfo.environment["AGENTDECK_REAL_CHECK"] == "1" {
            try await realCheck(executable)
        } else {
            approvalScopes()
            deletionRegression()
            try await transport(executable)
            try await workflow(executable)
            try await canvasWorkflow(executable)
            try await whiteboard(executable)
            try await attachmentAndSubscriptionRegression(executable)
        }
    }

    static func approvalScopes() {
        let command = Approval(id: "cmd", method: "item/commandExecution/requestApproval", params: [
            "threadId": "managed", "command": .string("echo \u{202E}test"), "availableDecisions": ["decline"]
        ], item: nil)
        precondition(command?.canAllow == false && command?.details.contains("\\u{202e}") == true)
        precondition(command?.response(allow: true) == ["decision": "decline"])
        let missingScope = Approval(id: "network", method: "item/commandExecution/requestApproval", params: [
            "threadId": "managed", "networkApprovalContext": ["host": "example.test"]
        ], item: nil)
        precondition(missingScope?.canAllow == false)

        let changes: WireValue = ["changes": [["path": "example.txt", "diff": "-before\n+after"]]]
        let edit = Approval(id: "edit", method: "item/fileChange/requestApproval",
                            params: ["threadId": "managed"], item: changes)
        precondition(edit?.canAllow == true && edit?.response(allow: true) == ["decision": "accept"])
        let grant = Approval(id: "grant", method: "item/fileChange/requestApproval",
                             params: ["threadId": "managed", "grantRoot": "/tmp"], item: changes)
        precondition(grant?.canAllow == false)

        let permission = Approval(id: "permissions", method: "item/permissions/requestApproval",
                                  params: ["threadId": "managed", "permissions": ["network": ["enabled": true]]],
                                  item: nil)
        precondition(permission?.response(allow: true) == ["permissions": [:], "scope": "turn"])
        print("Passed approval scope and visible-text checks")
    }

    @MainActor
    static func deletionRegression() {
        let suite = "AgentDeck.DeleteTest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        let project = store.addProject(FileManager.default.temporaryDirectory)!
        let agent = store.addPreset(.research, in: project, slot: .left)!
        precondition(store.remove(agent.id))
        precondition(store.profile(agent.id) == nil && store.agent(in: .left, project: project) == nil)
        let restored = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        precondition(restored.profile(agent.id) == nil)
        let invalid = Data("invalid saved data".utf8)
        defaults.set(invalid, forKey: "agentWorkspaceV2")
        let unreadable = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        precondition(unreadable.error != nil)
        precondition(!unreadable.save(AgentProfile(project: project.id, name: "Should not save")))
        precondition(defaults.data(forKey: "agentWorkspaceV2") == invalid)
        print("Passed deletion with populated legacy canvas, persistence, and unreadable-data preservation")
    }

    static func transport(_ executable: URL) async throws {
        let client = AppServer(deadline: .milliseconds(350))
        try await client.connect(executable: executable)
        let null = try await client.request("fixture/null")
        precondition(null == .null)
        do {
            _ = try await client.request("fixture/error")
            throw Failure.expectedFailure
        } catch ServerFailure.rpc(let method, let code, _) {
            precondition(method == "fixture/error" && code == -32601)
        }
        do {
            _ = try await client.request("fixture/stall")
            throw Failure.expectedFailure
        } catch ServerFailure.timeout(let method) { precondition(method == "fixture/stall") }

        let cancelled = Task { try await client.request("fixture/stall") }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw Failure.expectedFailure
        } catch is CancellationError {}

        do {
            _ = try await client.request("fixture/malformed")
            throw Failure.expectedFailure
        } catch ServerFailure.invalidFrame {}
        await client.close()

        let conflicted = AppServer()
        try await conflicted.connect(executable: executable)
        do {
            _ = try await conflicted.request("fixture/conflict")
            throw Failure.expectedFailure
        } catch ServerFailure.invalidFrame {}
        await conflicted.close()

        let interrupted = AppServer()
        try await interrupted.connect(executable: executable)
        async let pending = interrupted.request("fixture/stall")
        do {
            _ = try await interrupted.request("fixture/eof")
            throw Failure.expectedFailure
        } catch ServerFailure.closed {}
        do {
            _ = try await pending
            throw Failure.expectedFailure
        } catch ServerFailure.closed {}
        await interrupted.close()
        print("Passed transport checks for errors, timeout, cancellation, malformed frames, and EOF")
    }

    @MainActor
    static func workflow(_ executable: URL) async throws {
        let suite = "AgentDeck.Test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let deck = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        deck.executable = executable
        await deck.connect()
        precondition(deck.connected && deck.error == nil)
        precondition(deck.models.first(where: \.isDefault)?.id == "fixture-model")
        precondition(Set(deck.mainChats.map(\.id)) == ["observed", "writer"])
        precondition(deck.thread("helper")?.parent == "observed")
        guard let project = deck.addProject(FileManager.default.temporaryDirectory) else { throw Failure.expectedFailure }
        await deck.refresh()
        await deck.loadHistory("observed")
        precondition(deck.chat("observed").contains { $0.text == "Saved message" })
        precondition(!deck.canControl("observed"))
        await deck.refreshObservedHistory("observed")
        precondition(deck.chat("observed").count == 1 && deck.chat("observed")[0].text == "Updated message")
        let refused = await deck.sendMain("blocked", project: project, expectedTurn: nil)
        precondition(!refused)
        deck.dismissError()

        var first = AgentProfile(project: project.id, name: "Reviewer", instructions: "Review carefully", model: "fixture-model", effort: "medium")
        let second = AgentProfile(project: project.id, name: "Builder", instructions: "Build carefully")
        precondition(deck.save(first) && deck.save(second))
        let sentFirst = await deck.send("Review the sample", agent: first.id, expectedTurn: nil)
        precondition(sentFirst)
        try await waitFor { deck.approvals.count == 1 }
        precondition(deck.approvals[0].canAllow)
        await deck.decide("approval", allow: false)
        try await waitFor { deck.approvals.isEmpty }
        try await waitFor { deck.profile(first.id)?.thread != nil }
        guard let firstThread = deck.profile(first.id)?.thread else { throw Failure.expectedFailure }
        let sentSecond = await deck.send("Build the sample", agent: second.id, expectedTurn: nil)
        precondition(sentSecond)
        guard let secondThread = deck.profile(second.id)?.thread else { throw Failure.expectedFailure }
        precondition(firstThread != secondThread)
        try await waitFor { !deck.chat(firstThread).isEmpty && !deck.chat(secondThread).isEmpty }
        precondition(deck.chat(firstThread).contains { $0.text.contains("Review the sample") })
        precondition(deck.chat(secondThread).contains { $0.text.contains("Build the sample") })
        first = deck.profile(first.id)!
        first.instructions = "Updated role"
        precondition(deck.save(first))
        try await waitFor { deck.activeTurn(firstThread) == nil && deck.activeTurn(secondThread) == nil }
        precondition(deck.tasks(firstThread).contains { $0.title == "Review the sample" })
        precondition(deck.tokens(firstThread).lifetime == 108)
        let changedModel = await deck.sendThread("Model selection test", thread: firstThread, expectedTurn: nil,
                                                 model: "other-model", effort: "low")
        precondition(changedModel)
        try await waitFor { deck.activeTurn(firstThread) == nil }
        let invalidModel = await deck.sendThread("Must not send", thread: firstThread, expectedTurn: nil,
                                                 model: "other-model", effort: "medium")
        precondition(!invalidModel && deck.error != nil)
        deck.dismissError()
        let holding = await deck.send("Hold", agent: first.id, expectedTurn: nil)
        precondition(holding)
        guard let active = deck.activeTurn(firstThread) else { throw Failure.expectedFailure }
        precondition(deck.work(firstThread) == "Hold" && !deck.remove(first.id))
        deck.dismissError()
        await deck.interrupt(firstThread, expectedTurn: active)
        try await waitFor { deck.activeTurn(firstThread) == nil }
        precondition(deck.remove(second.id) && deck.profile(second.id) == nil)
        precondition(deck.newConversation(first.id))
        precondition(deck.profile(first.id)?.thread == nil)
        let newChatSent = await deck.send("Another review", agent: first.id, expectedTurn: nil)
        precondition(newChatSent)
        guard let newThread = deck.profile(first.id)?.thread else { throw Failure.expectedFailure }
        precondition(newThread != firstThread)
        try await waitFor { deck.activeTurn(newThread) == nil }
        guard let current = deck.profile(first.id) else { throw Failure.expectedFailure }
        precondition(deck.tokens(for: current).session == 108 && deck.tokens(for: current).lifetime == 216)
        precondition(deck.tasks(for: current).contains { $0.title == "Review the sample" })
        await deck.disconnect()
        let restarted = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        precondition(restarted.profile(first.id)?.instructions == "Updated role")
        precondition(restarted.profile(second.id) == nil)
        await restarted.connect()
        precondition(restarted.connected)
        let resumed = await restarted.send("Continue review", agent: first.id, expectedTurn: nil)
        precondition(resumed && restarted.profile(first.id)?.thread == newThread)
        try await waitFor { restarted.activeTurn(newThread) == nil }
        precondition(restarted.tokens(newThread).lifetime == 108)
        await restarted.disconnect()
        print("Passed observed safety, independent agent chats, and profile persistence checks")
    }

    @MainActor
    static func canvasWorkflow(_ executable: URL) async throws {
        let suite = "AgentDeck.CanvasTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        store.executable = executable
        await store.connect()
        guard let project = store.addProject(FileManager.default.temporaryDirectory),
              let qa = store.addPreset(.qa, in: project, slot: .lowerLeft) else { throw Failure.expectedFailure }

        await store.runWorkflow("Canvas smoke task", in: project)
        precondition(store.error?.contains("center slot") == true)
        store.dismissError()

        guard let center = store.addPreset(.development, in: project, slot: .center),
              let research = store.addPreset(.research, in: project, slot: .left) else { throw Failure.expectedFailure }
        precondition(store.placeAgent(research.id, in: .right, project: project))
        precondition(store.agent(in: .left, project: project) == nil)
        precondition(store.agent(in: .right, project: project)?.id == research.id)
        store.removeAgent(from: .right, project: project)
        precondition(store.profile(research.id) != nil && store.agent(in: .right, project: project) == nil)

        await store.runWorkflow("Canvas smoke task", in: project)
        precondition(store.workflowStatus(in: project) == "Workflow complete", store.error ?? "missing workflow status")
        guard let root = store.mainThread(in: project), let centerThread = store.profile(center.id)?.thread,
              let qaThread = store.profile(qa.id)?.thread else { throw Failure.expectedFailure }
        precondition(Set([root.id, centerThread, qaThread]).count == 3)
        precondition(store.chat(centerThread).contains { $0.isUser && $0.text.contains("Root work brief") })
        precondition(store.chat(qaThread).contains { $0.isUser && $0.text.contains("Center branch result") })
        precondition(store.chat(root.id).contains { $0.isUser && $0.text.contains("QA branch result") })
        await store.disconnect()
        let reopened = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        precondition(reopened.agent(in: .center, project: project)?.id == center.id)
        precondition(reopened.agent(in: .lowerLeft, project: project)?.id == qa.id)
        print("Passed canvas placement, persistence, staged handoffs, and result summary")
    }

    @MainActor
    static func whiteboard(_ executable: URL) async throws {
        let suite = "AgentDeck.WhiteboardTest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        store.executable = executable
        await store.connect()
        guard let project = store.addProject(FileManager.default.temporaryDirectory) else { throw Failure.expectedFailure }
        var agent = AgentProfile(project: project.id, name: "Research", instructions: "Read only",
                                 model: "other-model", effort: "low")
        agent.parentThread = "observed"
        agent.task = "Whiteboard task"
        agent.positionX = 100
        agent.positionY = 80
        precondition(store.save(agent))
        let unattached = await store.runAgent(agent.id)
        precondition(!unattached && store.profile(agent.id)?.thread == nil)
        store.dismissError()
        let attached = await store.attachChat("observed")
        precondition(attached)
        let began = await store.runAgent(agent.id)
        precondition(began)
        try await waitFor { store.profile(agent.id).map { store.agentStatus($0) == "Finished" } == true }
        let current = store.profile(agent.id)!
        precondition(current.thread == "native-child" && current.parentThread == "observed")
        precondition(store.profiles(inChat: "different-chat").isEmpty)
        precondition(store.profiles(inChat: "observed").count == 1)
        precondition(store.result(for: current) == "Whiteboard finished successfully.")
        precondition(store.tokens(for: current).lifetime == 108)
        precondition(store.tokens(for: current).input == 100 && store.tokens(for: current).output == 8)
        precondition(store.events.isEmpty && store.chat(current.thread!).isEmpty)
        let duplicate = await store.addExistingSubagent("native-child", parent: "observed")
        precondition(duplicate && store.profiles(inChat: "observed").count == 1)
        let unrelated = await store.addExistingSubagent("observed", parent: "observed")
        precondition(!unrelated)
        let held = await store.sendThread("Hold parent", thread: "observed", expectedTurn: nil)
        precondition(held)
        let routed = await store.runAgent(agent.id)
        precondition(routed)
        try await waitFor { store.activeTurn("native-child") == "child-active" }
        precondition(store.canControl("native-child"))
        await store.interrupt("native-child", expectedTurn: "child-active")
        try await waitFor { store.agentStatus(store.profile(agent.id)!) == "Interrupted" }
        await store.interrupt("observed", expectedTurn: "parent-held")
        try await waitFor { !store.hasActiveWork }
        await store.disconnect()
        let reopened = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        let restored = reopened.profile(agent.id)!
        precondition(restored.task == "Whiteboard task" && restored.positionX == 100 && restored.positionY == 80)
        precondition(reopened.result(for: restored) == "Whiteboard finished successfully.")
        precondition(reopened.agentStatus(restored) == "Interrupted")
        precondition(reopened.tokens(for: restored).lifetime == 108)
        precondition(reopened.profiles(in: Project(folder: "/different-project")).isEmpty)
        print("Passed selected-parent delegation with zero new main chats, verified child mapping, results, tokens and persistence")
    }

    @MainActor
    static func attachmentAndSubscriptionRegression(_ executable: URL) async throws {
        let suite = "AgentDeck.SubscriptionTest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = SubscriptionAuditClient()
        let store = WorkspaceStore(defaults: defaults, makeClient: { client })
        store.executable = executable
        await store.connect()
        let writerAttached = await store.attachChat("writer")
        precondition(writerAttached && store.chatAttached("writer") && store.usesChatQueue("writer"))
        precondition(!store.canControl("writer"))
        var queued = AgentProfile(project: "/tmp", name: "Test")
        queued.parentThread = "writer"
        queued.task = "Reply OK"
        precondition(store.save(queued))
        let queuedResult = await store.runAgent(queued.id)
        precondition(queuedResult && store.agentStatus(queued) == "Queued for main chat")
        precondition(store.profile(queued.id)?.thread == nil)
        await store.refreshObservedSessions()
        let finished = store.profile(queued.id)!
        let completions = store.completions(for: finished)
        precondition(finished.thread == "writer-child" && store.agentStatus(finished) == "Finished")
        precondition(completions.count == 1 && completions[0].durationMs == 2500 && completions[0].date != nil && completions[0].tokens == nil)
        await store.refreshObservedSessions()
        precondition(store.completions(for: finished).count == 1)
        let helperAttached = await store.attachChat("guardian")
        precondition(!helperAttached && !store.chatAttached("guardian"))
        store.dismissError()
        let failed = await store.attachChat("observed")
        precondition(!failed && !store.chatAttached("observed") && !store.canControl("observed"))
        store.dismissError()
        let attached = await store.attachChat("observed")
        precondition(attached && store.chatAttached("observed"))
        var profile = AgentProfile(project: "/tmp", name: "Audit", instructions: "Read only", model: "other-model", effort: "low")
        profile.parentThread = "observed"
        profile.task = "Whiteboard task"
        precondition(store.save(profile))
        let sent = await store.runAgent(profile.id)
        precondition(sent)
        // The child subscription is deliberately held open. Parent completion and tokens must still arrive.
        try await waitFor { store.activeTurn("observed") == nil && store.tokens("native-child").lifetime == 108 }
        let waiting = await client.isWaiting()
        precondition(waiting)
        await client.release()
        for _ in 0..<100 {
            if await client.childHistoryCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let attempts = await client.resumeCount()
        let histories = await client.childHistoryCount()
        precondition(attempts == 2 && histories == 1)
        await store.disconnect()
        print("Passed failed-attach rollback, uninterrupted event delivery, and transient child-subscription retry")
    }

    @MainActor
    static func realCheck(_ executable: URL) async throws {
        let client = AppServer(shared: ProcessInfo.processInfo.environment["AGENTDECK_SHARED_CHECK"] == "1")
        try await client.connect(executable: executable)
        let models = try await client.request("model/list", ["limit": 100])
        precondition(!models["data"].array.isEmpty)
        let threads = try await client.request("thread/list", ["limit": 10, "useStateDbOnly": true])
        if let id = threads["data"].array.first?["id"].string {
            let thread = try await client.request("thread/read", ["threadId": .string(id), "includeTurns": false])
            precondition(thread["thread"]["id"].string == id)
            let history = try await client.request("thread/turns/list", [
                "threadId": .string(id), "limit": 1, "itemsView": "summary"
            ])
            precondition(history.contains("data"))
            print("Installed CLI returned stored history without resuming a thread")
        }
        if ProcessInfo.processInfo.environment["AGENTDECK_ISOLATED_START"] == "1" {
            let started = try await client.request("thread/start", [
                "cwd": .string(FileManager.default.temporaryDirectory.path), "ephemeral": true
            ])
            guard let id = started["thread"]["id"].string else { throw Failure.expectedFailure }
            let loaded = try await client.request("thread/loaded/list", [:])
            precondition(loaded["data"].array.contains(.string(id)))
            print("Installed CLI created an isolated ephemeral thread and listed it as loaded")
        }
        if ProcessInfo.processInfo.environment["AGENTDECK_REAL_TURN"] == "1" {
            let catalog = models["data"].array.compactMap(ModelOption.init)
            guard let model = catalog.first(where: \.isDefault) ?? catalog.first else {
                throw Failure.expectedFailure
            }
            try await realTurn(client, model: model.id)
        }
        if ProcessInfo.processInfo.environment["AGENTDECK_REAL_DELEGATION"] == "1" {
            try await realDelegation(client, models: models["data"].array.compactMap(ModelOption.init))
        }
        await client.close()
        print("Verified Swift transport with installed CLI: \(models["data"].array.count) models, \(threads["data"].array.count) threads on first page")
    }

    @MainActor
    static func realDelegation(_ client: AppServer, models: [ModelOption]) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-delegation-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let model = models.first(where: \.isDefault) ?? models.first else { throw Failure.expectedFailure }
        print("Delegation check · creating disposable parent")
        let parent = try await client.request("thread/start", [
            "cwd": .string(folder.path), "sandbox": "read-only", "model": .string(model.id)
        ])
        guard let parentID = parent["thread"]["id"].string else { throw Failure.expectedFailure }
        _ = try await client.request("turn/start", [
            "threadId": .string(parentID), "model": .string(model.id),
            "input": [["type": "text", "text": "Reply READY. Do not use tools or read or change files."]]
        ])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in client.events {
                    if case .notification(let method, let params) = event,
                       method == "turn/completed", params["threadId"].string == parentID {
                        guard params["turn"]["status"].string == "completed" else { throw Failure.expectedFailure }
                        return
                    }
                }
                throw ServerFailure.closed
            }
            group.addTask { try await Task.sleep(for: .seconds(55)); throw Failure.timedOut }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        let suite = "AgentDeck.RealDelegation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = RecordingClient()
        let store = WorkspaceStore(defaults: defaults, makeClient: { proxy })
        store.executable = URL(fileURLWithPath: CommandLine.arguments[1])
        print("Delegation check · connecting second shared client")
        await store.connect()
        print("Delegation check · connected: \(store.connected), error: \(store.error ?? "none")")
        let didAttach = await store.attachChat(parentID)
        print("Delegation check · attach outcome: \(didAttach), error: \(store.error ?? "none")")
        guard didAttach else {
            let detail = store.error ?? "Could not attach the isolated parent."
            await proxy.close()
            _ = try? await client.request("thread/archive", ["threadId": .string(parentID)])
            throw WorkflowIssue(detail)
        }
        print("Delegation check · attached existing parent")
        var agent = AgentProfile(project: folder.path, name: "Read-only verification", instructions: "Reply with exactly DONE. Do not use tools or read or change files.", model: model.id)
        agent.parentThread = parentID
        agent.task = "Reply with exactly DONE. Do not use tools or read or change files."
        precondition(store.save(agent))
        guard await store.runAgent(agent.id) else {
            await proxy.close()
            _ = try? await client.request("thread/archive", ["threadId": .string(parentID)])
            throw WorkflowIssue(store.error ?? "Could not submit delegated work.")
        }
        print("Delegation check · parent request accepted")
        for iteration in 0..<100 {
            if let profile = store.profile(agent.id), profile.thread != nil, store.agentStatus(profile) == "Finished" {
                guard let child = profile.thread, store.thread(child)?.parent == parentID,
                      store.result(for: profile)?.isEmpty == false else { throw Failure.expectedFailure }
                print("Shared daemon spawned a verified child beneath the selected existing parent and returned its final result")
                print("Child token usage available: \(store.tokens(for: profile).lifetime != nil)")
                await proxy.close()
                _ = try? await client.request("thread/archive", ["threadId": .string(parentID)])
                return
            }
            if iteration > 10 && !store.tasks(parentID).isEmpty && store.profile(agent.id)?.thread == nil { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        for summary in await proxy.summaries() { print(summary) }
        let detail = store.error ?? "Delegation did not complete within 90 seconds."
        print("Delegation diagnostics · child mapped: \(store.profile(agent.id)?.thread != nil), status: \(store.profile(agent.id).map { store.agentStatus($0) } ?? "missing"), reported descendants: \(store.subagents(inChat: parentID).count)")
        if let reply = store.chat(parentID).last(where: { !$0.isUser })?.text {
            print("Disposable parent reply: \(String(reply.prefix(1200)))")
        }
        if let turn = store.activeTurn(parentID) { await store.interrupt(parentID, expectedTurn: turn) }
        await proxy.close()
        _ = try? await client.request("thread/archive", ["threadId": .string(parentID)])
        throw WorkflowIssue(detail)
    }

    static func realTurn(_ client: AppServer, model: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = try await client.request("thread/start", [
            "cwd": .string(folder.path), "ephemeral": true, "sandbox": "read-only", "model": .string(model)
        ])
        guard let id = started["thread"]["id"].string else { throw Failure.expectedFailure }
        _ = try await client.request("turn/start", [
            "threadId": .string(id), "model": .string(model),
            "input": [["type": "text", "text": "Reply with the single word OK. Do not call tools or read or change any files."]]
        ])
        let stream = client.events
        try await withThrowingTaskGroup(of: Void.self) { checks in
            checks.addTask {
                var streamedText = false
                var tokenUsage = false
                for await event in stream {
                    if case .request(let id, _, _) = event {
                        try await client.reject(id: id)
                        throw Failure.expectedFailure
                    }
                    guard case .notification(let method, let params) = event,
                          params["threadId"].string == id else { continue }
                    if method == "item/agentMessage/delta", !(params["delta"].string ?? "").isEmpty {
                        streamedText = true
                    }
                    if method == "thread/tokenUsage/updated" {
                        tokenUsage = params["tokenUsage"]["total"]["totalTokens"].int != nil
                    }
                    if method == "turn/completed" {
                        guard params["turn"]["status"].string == "completed" else {
                            let detail = params["turn"]["error"]["message"].string ?? "Turn did not complete."
                            throw ServerFailure.rpc("real-turn check", -1, String(detail.prefix(240)))
                        }
                        guard streamedText, tokenUsage else { throw Failure.expectedFailure }
                        return
                    }
                }
                throw ServerFailure.closed
            }
            checks.addTask {
                try await Task.sleep(for: .seconds(55))
                throw Failure.timedOut
            }
            defer { checks.cancelAll() }
            _ = try await checks.next()
        }
        print("Installed CLI completed a read-only ephemeral turn and streamed text and token usage")
    }

    @MainActor
    static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timedOut
    }
}

actor RecordingClient: CodexClient {
    private let base = AppServer(shared: true)
    private let continuation: AsyncStream<ServerEvent>.Continuation
    nonisolated let events: AsyncStream<ServerEvent>
    private var listener: Task<Void, Never>?
    private var recorded: [ServerEvent] = []
    init() { (events, continuation) = AsyncStream.makeStream() }
    func connect(executable: URL) async throws {
        try await base.connect(executable: executable)
        listener = Task { [weak self, stream = base.events] in
            for await event in stream { await self?.record(event) }
        }
    }
    private func record(_ event: ServerEvent) { recorded.append(event); continuation.yield(event) }
    func request(_ method: String, _ params: WireValue) async throws -> WireValue { try await base.request(method, params) }
    func reply(id: WireValue, result: WireValue) async throws { try await base.reply(id: id, result: result) }
    func reject(id: WireValue) async throws { try await base.reject(id: id) }
    func close(_ error: ServerFailure = .closed) async {
        await base.close(error)
        listener?.cancel()
        continuation.finish()
    }
    func summaries() -> [String] {
        recorded.compactMap { event in
            guard case .notification(let method, let params) = event else { return nil }
            let item = params["item"]
            if method == "item/completed" || method.contains("agent") || method.contains("Agent") {
                let fields: String
                if case .object(let object) = item { fields = object.keys.sorted().joined(separator: ",") } else { fields = "" }
                return "\(method) type=\(item["type"].string ?? "?") tool=\(item["tool"].string ?? item["name"].string ?? "?") fields=\(fields)"
            }
            return nil
        }
    }
}

actor SubscriptionAuditClient: CodexClient {
    private let base = AppServer()
    nonisolated let events: AsyncStream<ServerEvent>
    private var failAttach = true
    private var gate: CheckedContinuation<Void, Never>?
    private var resumes = 0
    private var histories = 0
    init() { events = base.events }
    func connect(executable: URL) async throws { try await base.connect(executable: executable) }
    func request(_ method: String, _ params: WireValue) async throws -> WireValue {
        if method == "thread/turns/list", params["threadId"].string == "observed", failAttach {
            failAttach = false
            throw ServerFailure.rpc(method, -1, "Intentional attach lookup failure")
        }
        if method == "thread/resume", params["threadId"].string == "native-child" {
            resumes += 1
            if resumes == 1 {
                await withCheckedContinuation { gate = $0 }
                throw ServerFailure.rpc(method, -32600, "no rollout found for thread id native-child")
            }
        }
        if method == "thread/turns/list", params["threadId"].string == "native-child" { histories += 1 }
        return try await base.request(method, params)
    }
    func isWaiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func resumeCount() -> Int { resumes }
    func childHistoryCount() -> Int { histories }
    func reply(id: WireValue, result: WireValue) async throws { try await base.reply(id: id, result: result) }
    func reject(id: WireValue) async throws { try await base.reject(id: id) }
    func close(_ error: ServerFailure) async { release(); await base.close(error) }
}
