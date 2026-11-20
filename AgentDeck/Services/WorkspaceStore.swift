import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceStore {
    private struct Saved: Codable {
        var folders: Set<String> = []
        var profiles: [AgentProfile] = []
        var owned: Set<String> = []
        var main: [String: String] = [:]
        var meters: [String: UsageLedger] = [:]
        var canvas: [String: [String: String]]?
        var completedResults: [String: String]?
        var completionStates: [String: String]?
        var whiteboardMigrated: Bool?
        var delegationStates: [String: String]?
        var agentCompletions: [String: [AgentCompletion]]?
        var queuedAt: [String: Date]?
    }

    private struct ThreadView {
        var turn: String?
        var lastFinished: String?
        var lastSubmitted: String?
        var replies: [String: String] = [:]
        var results: [String: WorkflowResult] = [:]
        var request: String?
        var planStep: String?
        var messages: [ConversationEntry] = []
        var completed: [AgentTask] = []
        var hydrated = false
        var older: String?
    }

    private struct WorkflowResult {
        let status: String
        let reply: String
    }

    private(set) var connected = false
    private(set) var connecting = false
    private(set) var models: [ModelOption] = []
    private(set) var approvals: [Approval] = []
    private(set) var error: String?
    var executable: URL? {
        didSet { defaults.set(executable?.path, forKey: "workspaceCLI") }
    }

    private let defaults: UserDefaults
    private let makeClient: @Sendable () -> any CodexClient
    private var saved: Saved
    private var savedReadFailed = false
    private var client: (any CodexClient)?
    private var connection: UUID?
    private var listener: Task<Void, Never>?
    private var subscriptionTasks: [String: Task<Void, Never>] = [:]
    private var records: [String: CodexThread] = [:]
    private var order: [String] = []
    private var view: [String: ThreadView] = [:]
    private var loaded: Set<String> = []
    private var attachedChats: Set<String> = []
    private var queuedChats: Set<String> = []
    private var operations: Set<String> = []
    private var openItems: [String: [String: WireValue]] = [:]
    private var nextPage: String?
    private var pagedProjects = false
    private var listing = false
    private(set) var workflows: [DeckWorkflow] = []
    private var libraryReadFailed = false
    private var runGraphs: [UUID: DeckWorkflow] = [:]
    private var runThreads: [UUID: [UUID: String]] = [:]
    private var agentStates: [String: String] = [:]
    private(set) var events: [DeckEvent] = []
    private(set) var weeklyAllowance = "Weekly allowance unavailable through this connection."
    private(set) var serverVersion = "Version unavailable"
    private var authenticationRequired = false
    private var connectionError = false
    var connectionStatus: String {
        if connecting { return "Connecting" }
        if authenticationRequired { return "Authentication required" }
        if connected { return "Connected" }
        if executable == nil { return "Codex unavailable" }
        return connectionError ? "Connection error" : "Disconnected"
    }
    var threads: [CodexThread] { order.compactMap { records[$0] } }
    var mainChats: [CodexThread] { threads.filter(\.isMainChat) }
    private var workflowRuns: Set<String> = []
    private var workflowMessages: [String: String] = [:]
    private static let storageKey = "agentWorkspaceV2"

    init(defaults: UserDefaults = .standard, makeClient: @escaping @Sendable () -> any CodexClient = { AppServer(shared: true) }) {
        self.defaults = defaults
        self.makeClient = makeClient
        if let data = defaults.data(forKey: Self.storageKey) {
            do { saved = try JSONDecoder().decode(Saved.self, from: data) }
            catch {
                saved = Saved()
                savedReadFailed = true
                self.error = "Saved app data could not be read. Its original contents are preserved."
            }
        } else { saved = Saved() }
        if let data = defaults.data(forKey: "deckWorkflowLibrary") {
            do { workflows = try JSONDecoder().decode([DeckWorkflow].self, from: data)
                for workflow in workflows { try workflow.validate() }
            } catch {
                libraryReadFailed = true
                self.error = "The workflow library could not be read. Its saved data has been preserved."
            }
        } else {
            for folder in (saved.canvas ?? [:]).keys.sorted() {
                var workflow = DeckWorkflow(folder: folder)
                workflow.name = Project(folder: folder).name + " Workflow"
                for (index, slot) in WorkflowSlot.allCases.enumerated() {
                    guard let id = saved.canvas?[folder]?[slot.rawValue],
                          let profile = saved.profiles.first(where: { $0.id == id && !$0.removed }) else { continue }
                    workflow.nodes[index + 1].name = profile.name
                    workflow.nodes[index + 1].instructions = profile.instructions
                    workflow.nodes[index + 1].model = profile.model
                    workflow.nodes[index + 1].effort = profile.effort
                }
                workflows.append(workflow)
            }
            if !workflows.isEmpty, let data = try? JSONEncoder().encode(workflows) {
                defaults.set(data, forKey: "deckWorkflowLibrary")
            }
        }
        executable = defaults.string(forKey: "workspaceCLI").map { URL(fileURLWithPath: $0) } ?? Self.findCLI()
        if saved.whiteboardMigrated != true {
            for workflow in workflows {
                guard Self.folderKey(workflow.folder) != nil else { continue }
                for node in workflow.nodes where node.id != workflow.rootID && !node.name.isEmpty {
                    guard !saved.profiles.contains(where: { $0.id == node.id.uuidString }) else { continue }
                    var profile = AgentProfile(project: workflow.folder, name: node.name, instructions: node.instructions,
                                               model: node.model, effort: node.effort)
                    profile.id = node.id.uuidString
                    profile.task = node.task
                    saved.profiles.append(profile)
                    saved.folders.insert(workflow.folder)
                }
            }
            saved.whiteboardMigrated = true
            persist()
        }
    }

    private static func findCLI() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    var projects: [Project] {
        saved.folders.union(records.values.compactMap { Self.folderKey($0.folder) })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(Project.init(folder:))
    }

    var hasMoreProjects: Bool { nextPage != nil }
    var hasActiveWork: Bool { view.values.contains { $0.turn != nil } || !operations.isEmpty || !approvals.isEmpty || !workflowRuns.isEmpty || agentStates.values.contains("Running") }

    func addProject(_ folder: URL) -> Project? {
        guard folder.isFileURL, let key = Self.folderKey(folder.path),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            error = "Choose an existing project folder."
            return nil
        }
        saved.folders.insert(key)
        persist()
        return Project(folder: key)
    }

    func mainChoices(in project: Project) -> [CodexThread] {
        let agentThreads = Set(saved.profiles.flatMap { [$0.thread].compactMap { $0 } + ($0.previousThreads ?? []) })
        return order.compactMap { records[$0] }.filter {
            $0.isMainChat && !agentThreads.contains($0.id) && Self.folderKey($0.folder) == project.id
        }
    }

    func mainThread(in project: Project) -> CodexThread? {
        let choices = mainChoices(in: project)
        return choices.first { $0.id == saved.main[project.id] } ?? choices.first
    }

    func mainModel(in project: Project) -> String? {
        if let main = mainThread(in: project) { return main.model }
        return defaultModel?.name
    }

    func selectMain(_ id: String, in project: Project) {
        guard mainChoices(in: project).contains(where: { $0.id == id }) else { return }
        saved.main[project.id] = id
        persist()
    }

    func profiles(in project: Project) -> [AgentProfile] {
        saved.profiles.filter { $0.project == project.id && !$0.removed }
    }

    func nativeAgents(in project: Project) -> [CodexThread] {
        let roots = [mainThread(in: project)?.id] + profiles(in: project).map(\.thread)
        let ids = Set(roots.compactMap { $0 })
        return order.compactMap { records[$0] }.filter { row in
            !ids.contains(row.id) && ancestor(row.id, in: ids) != nil
        }
    }

    private func ancestor(_ id: String, in roots: Set<String>) -> String? {
        var seen: Set<String> = [id]
        var cursor = records[id]?.parent
        while let parent = cursor, seen.insert(parent).inserted {
            if roots.contains(parent) { return parent }
            cursor = records[parent]?.parent
        }
        return nil
    }

    func profile(_ id: String) -> AgentProfile? { saved.profiles.first { $0.id == id && !$0.removed } }
    func thread(_ id: String) -> CodexThread? { records[id] }
    func tokens(_ id: String) -> UsageLedger { saved.meters[id] ?? UsageLedger() }
    func tokens(for profile: AgentProfile) -> UsageLedger {
        var meter = profile.thread.map(tokens) ?? UsageLedger()
        for previous in profile.previousThreads ?? [] { meter.includePrevious(tokens(previous)) }
        return meter
    }

    func tasks(for profile: AgentProfile) -> [AgentTask] {
        ([profile.thread].compactMap { $0 } + (profile.previousThreads ?? []))
            .flatMap(tasks).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    func hasOlder(for profile: AgentProfile) -> Bool {
        ([profile.thread].compactMap { $0 } + (profile.previousThreads ?? [])).contains(where: hasOlder)
    }

    func loadProfileHistory(_ id: String, more: Bool = false) async {
        guard let profile = profile(id) else { return }
        let threads = [profile.thread].compactMap { $0 } + Array((profile.previousThreads ?? []).reversed())
        if more {
            if let next = threads.first(where: hasOlder) { await loadHistory(next, more: true) }
        } else {
            for thread in threads {
                if Task.isCancelled { return }
                await loadHistory(thread)
            }
        }
    }

    func tasks(_ id: String) -> [AgentTask] { view[id]?.completed ?? [] }
    func chat(_ id: String) -> [ConversationEntry] { view[id]?.messages ?? [] }
    func activeTurn(_ id: String) -> String? { view[id]?.turn }
    func canControl(_ id: String) -> Bool { connected && (saved.owned.contains(id) || attachedChats.contains(id) || ancestor(id, in: attachedChats) != nil) }
    func hasOlder(_ id: String) -> Bool { view[id]?.older != nil }
    func work(_ id: String) -> String? {
        if approvals.contains(where: { $0.thread == id }) { return "Waiting for approval" }
        guard activeTurn(id) != nil || records[id]?.active == true else { return nil }
        return view[id]?.planStep ?? view[id]?.request ?? "Working"
    }

    @discardableResult
    func save(_ profile: AgentProfile) -> Bool {
        guard writableSavedData() else { return false }
        var entry = profile
        entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.name.isEmpty, entry.name.count <= 40, entry.instructions.utf8.count <= 6_000,
              (entry.task?.utf8.count ?? 0) <= 12_000,
              [entry.positionX, entry.positionY].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }),
              projects.contains(where: { $0.id == entry.project }) else {
            error = "Enter an agent name (up to 40 characters) and up to 6,000 bytes of instructions."
            return false
        }
        if let index = saved.profiles.firstIndex(where: { $0.id == entry.id }) {
            guard !saved.profiles[index].removed, saved.profiles[index].project == entry.project else { return false }
            entry.removed = false
            entry.parentThread = saved.profiles[index].parentThread
            entry.thread = saved.profiles[index].thread
            entry.previousThreads = saved.profiles[index].previousThreads
            saved.profiles[index] = entry
        } else {
            entry.thread = nil
            entry.previousThreads = nil
            entry.removed = false
            saved.profiles.append(entry)
        }
        saved.folders.insert(entry.project)
        persist()
        return true
    }

    func newConversation(_ id: String) -> Bool {
        guard let index = saved.profiles.firstIndex(where: { $0.id == id && !$0.removed }),
              let thread = saved.profiles[index].thread, mayRetire(id, thread: thread) else { return false }
        saved.profiles[index].previousThreads = (saved.profiles[index].previousThreads ?? []) + [thread]
        saved.profiles[index].thread = nil
        persist()
        return true
    }

    private func mayRetire(_ id: String, thread: String?) -> Bool {
        let pending = saved.delegationStates?[id]
        let parentBusy = profile(id)?.parentThread.flatMap(activeTurn) != nil
        if (parentBusy && (pending == "Delegation requested" || pending == "Task routed through parent"))
            || profile(id).map({ workflowRuns.contains($0.project) }) == true
            || operations.contains(id) || thread.map({ thread in
            activeTurn(thread) != nil || operations.contains(thread)
              || view.contains(where: { $0.value.turn != nil && ancestor($0.key, in: [thread]) != nil })
              || approvals.contains(where: { $0.thread == thread || ancestor($0.thread, in: [thread]) != nil })
        }) == true {
            error = "Stop or finish the agent’s current task first."
            return false
        }
        return true
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        guard writableSavedData() else { return false }
        guard let index = saved.profiles.firstIndex(where: { $0.id == id && !$0.removed }),
              mayRetire(id, thread: saved.profiles[index].thread) else { return false }
        saved.profiles[index].removed = true
        saved.profiles[index].instructions = ""
        let project = saved.profiles[index].project
        let remainingSlots = saved.canvas?[project]?.filter { $0.value != id }
        saved.canvas?[project] = remainingSlots
        persist()
        return true
    }

    func agent(in slot: WorkflowSlot, project: Project) -> AgentProfile? {
        saved.canvas?[project.id]?[slot.rawValue].flatMap(profile)
    }

    @discardableResult
    func placeAgent(_ id: String, in slot: WorkflowSlot, project: Project) -> Bool {
        guard profile(id)?.project == project.id else { return false }
        var canvas = saved.canvas ?? [:]
        var slots = canvas[project.id, default: [:]]
        slots = slots.filter { $0.value != id }
        slots[slot.rawValue] = id
        canvas[project.id] = slots
        saved.canvas = canvas
        persist()
        return true
    }

    func removeAgent(from slot: WorkflowSlot, project: Project) {
        saved.canvas?[project.id]?.removeValue(forKey: slot.rawValue)
        persist()
    }

    @discardableResult
    func addPreset(_ preset: AgentPreset, in project: Project, slot: WorkflowSlot? = nil) -> AgentProfile? {
        let profile = AgentProfile(project: project.id, name: preset.name, instructions: preset.instructions)
        guard save(profile) else { return nil }
        if let slot { placeAgent(profile.id, in: slot, project: project) }
        return profile
    }

    func runningWorkflow(in project: Project) -> Bool { workflowRuns.contains(project.id) }
    func workflowStatus(in project: Project) -> String? { workflowMessages[project.id] }

    func dismissError() { error = nil }

    func connect() async {
        guard !connected, !connecting else { return }
        guard let executable else { error = ServerFailure.executable.localizedDescription; return }
        connecting = true
        error = nil
        let candidate = makeClient()
        let token = UUID()
        client = candidate
        connection = token
        defer { connecting = false }
        do {
            try await candidate.connect(executable: executable)
            guard connection == token else { await candidate.close(.closed); return }
            listener = Task { [weak self, events = candidate.events] in
                for await event in events {
                    guard let self, self.connection == token else { break }
                    await self.receive(event, from: candidate, connection: token)
                }
            }
            connected = true
            connectionError = false
            if let server = candidate as? AppServer { serverVersion = await server.serverIdentity }
            await refresh()
            let account = try? await candidate.request("account/read", ["refreshToken": false])
            guard connection == token else { return }
            authenticationRequired = account?["requiresOpenaiAuth"].bool == true && account?["account"] == .null
            if let limits = try? await candidate.request("account/rateLimits/read", [:]), connection == token {
                updateAllowance(limits)
            }
        } catch {
            guard connection == token else { return }
            await candidate.close(.closed)
            clearConnection()
            connectionError = true
            report(error)
        }
    }

    func disconnect() async {
        guard let client, !hasActiveWork else { return }
        clearConnection()
        await client.close(.closed)
    }

    private func clearConnection() {
        listener?.cancel()
        listener = nil
        for task in subscriptionTasks.values { task.cancel() }
        subscriptionTasks.removeAll()
        client = nil
        connection = nil
        connected = false
        authenticationRequired = false
        weeklyAllowance = "Weekly allowance unavailable through this connection."
        loaded.removeAll()
        attachedChats.removeAll()
        queuedChats.removeAll()
        pagedProjects = false
        nextPage = nil
        approvals.removeAll()
        openItems.removeAll()
        for id in Array(records.keys) { records[id]?.active = false }
        for id in Array(view.keys) { view[id]?.turn = nil }
    }

    func refresh() async {
        guard let client, let token = connection, connected, !listing else { return }
        await refreshObservedSessions()
        guard connection == token else { return }
        do {
            var collected: [ModelOption] = []
            var cursors: Set<String> = []
            var params: [String: WireValue] = ["limit": 100]
            repeat {
                let page = try await client.request("model/list", .object(params))
                guard connection == token else { return }
                for model in page["data"].array.compactMap(ModelOption.init)
                    where !collected.contains(where: { $0.id == model.id }) { collected.append(model) }
                guard let next = page["nextCursor"].string, cursors.insert(next).inserted, cursors.count < 10 else { break }
                params["cursor"] = .string(next)
            } while true
            models = collected
        } catch { if connection == token { report(error) } }
    }

    func refreshObservedSessions() async {
        guard let client, let token = connection, connected else { return }
        await listProjects(using: client, connection: token, cursor: nil)
        do {
            let page = try await client.request("thread/loaded/list", [:])
            guard connection == token else { return }
            for id in page["data"].array.compactMap(\.string).prefix(100) where records[id] == nil {
                let row = try await client.request("thread/read", ["threadId": .string(id), "includeTurns": false])
                guard connection == token else { return }
                ingest(row["thread"])
            }
        } catch { if connection == token { report(error) } }
        for parent in queuedChats {
            await refreshQueuedCompletions(parent, client: client, connection: token)
        }
    }

    private func refreshQueuedCompletions(_ parent: String, client: any CodexClient, connection token: UUID) async {
        do {
            let page = try await client.request("thread/turns/list", ["threadId": .string(parent), "limit": 30, "itemsView": "full"])
            guard connection == token else { return }
            for turn in page["data"].array.reversed() {
                for item in turn["items"].array where item["type"].string == "subAgentActivity" || item["type"].string == "collabAgentToolCall" {
                    update("item/completed", ["threadId": .string(parent), "item": item])
                }
            }
            for child in Set(profiles(inChat: parent).compactMap(\.thread)) {
                let turns = try await client.request("thread/turns/list", ["threadId": .string(child), "limit": 30, "itemsView": "notLoaded"])
                guard connection == token else { return }
                let metadata = try? await client.request("thread/read", ["threadId": .string(child), "includeTurns": false])
                var usage: [String: Int] = [:]
                if metadata?["thread"]["id"].string == child, let path = metadata?["thread"]["path"].string {
                    usage = await Task.detached { RecordedUsage.read(path: path, thread: child) }.value
                }
                guard connection == token else { return }
                for turn in turns["data"].array where turn["status"].string == "completed" {
                    recordCompletion(thread: child, turn: turn, tokens: turn["id"].string.flatMap { usage[$0] })
                }
            }
        } catch { /* A chat may not yet have a readable child history. Retry on refresh. */ }
    }

    func loadMoreProjects() async {
        guard let client, let token = connection, let nextPage else { return }
        await listProjects(using: client, connection: token, cursor: nextPage)
        if connection == token { pagedProjects = true }
    }

    private func listProjects(using client: any CodexClient, connection token: UUID, cursor: String?) async {
        guard connected, !listing else { return }
        listing = true
        defer { listing = false }
        do {
            var params: [String: WireValue] = [
                "limit": 50, "useStateDbOnly": true,
                "sourceKinds": ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
                                "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await client.request("thread/list", .object(params))
            guard connection == token else { return }
            let pageRecords = page["data"].array
            for record in pageRecords { ingest(record) }
            if cursor == nil {
                let firstPage = pageRecords.compactMap { $0["id"].string }
                let firstIDs = Set(firstPage)
                order = firstPage + order.filter { !firstIDs.contains($0) }
            }
            let next = page["nextCursor"].string
            if cursor != nil || !pagedProjects { nextPage = next == cursor ? nil : next }
        } catch { if connection == token { report(error) } }
    }

    func loadHistory(_ id: String, more: Bool = false) async {
        guard let client, let token = connection, connected,
              more ? hasOlder(id) : view[id]?.hydrated != true,
              operations.insert("history:" + id).inserted else { return }
        defer { operations.remove("history:" + id) }
        do {
            var params: [String: WireValue] = ["threadId": .string(id), "limit": 10, "itemsView": "full"]
            let cursor = more ? view[id]?.older : nil
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await client.request("thread/turns/list", .object(params))
            guard connection == token else { return }
            var state = view[id] ?? ThreadView()
            var known = Set(state.messages.map(\.id))
            var olderMessages: [ConversationEntry] = []
            for turn in page["data"].array.reversed() {
                let entries = turn["items"].array.compactMap(ConversationEntry.init)
                olderMessages += entries.filter { known.insert($0.id).inserted }
                if turn["status"].string == "completed", let turnID = turn["id"].string,
                   let task = entries.first(where: \.isUser)?.text, !state.completed.contains(where: { $0.id == turnID }) {
                    state.completed.append(AgentTask(id: turnID, title: task, date: Self.turnDate(turn)))
                }
            }
            state.messages.insert(contentsOf: olderMessages, at: 0)
            state.completed.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            state.hydrated = true
            let next = page["nextCursor"].string
            state.older = next == cursor ? nil : next
            view[id] = state
        } catch { if connection == token { report(error) } }
    }

    func refreshObservedHistory(_ id: String) async {
        guard let client, let token = connection, connected, !saved.owned.contains(id),
              operations.insert("history:" + id).inserted else { return }
        defer { operations.remove("history:" + id) }
        do {
            let page = try await client.request("thread/turns/list", [
                "threadId": .string(id), "limit": 10, "itemsView": "full"
            ])
            guard connection == token else { return }
            var state = view[id] ?? ThreadView()
            let entries = page["data"].array.reversed().flatMap { $0["items"].array.compactMap(ConversationEntry.init) }
            let entryIDs = Set(entries.map(\.id))
            state.messages.removeAll { entryIDs.contains($0.id) }
            state.messages.append(contentsOf: entries)
            if !state.hydrated {
                state.older = page["nextCursor"].string
                state.hydrated = true
            }
            view[id] = state
        } catch { if connection == token { report(error) } }
    }

    private var defaultModel: ModelOption? { models.first(where: \.isDefault) ?? models.first }

    func startMain(in project: Project) async {
        let lock = "main:" + project.id
        guard projects.contains(project), operations.insert(lock).inserted else { return }
        defer { operations.remove(lock) }
        do {
            let id = try await newThread(in: project.folder, model: defaultModel?.id)
            saved.main[project.id] = id
            saved.folders.insert(project.folder)
            persist()
        } catch { report(error) }
    }

    func send(_ text: String, agent id: String, expectedTurn: String?) async -> Bool {
        guard let agent = profile(id), let message = checkedMessage(text), operations.insert(id).inserted else { return false }
        defer { operations.remove(id) }
        do {
            let model = try model(for: agent)
            let thread: String
            if let current = agent.thread {
                thread = current
            } else {
                guard expectedTurn == nil else { throw ServerFailure.busy }
                thread = try await newThread(in: agent.project, model: model?.id)
                guard let index = saved.profiles.firstIndex(where: { $0.id == id && !$0.removed }) else { return false }
                saved.profiles[index].thread = thread
                persist()
            }
            let role = agent.instructions.isEmpty ? nil : "AgentDeck agent instructions\n" + agent.instructions
            return try await submit(message, thread: thread, model: model, effort: agent.effort,
                                    role: role, expectedTurn: expectedTurn)
        } catch { report(error); return false }
    }

    func sendMain(_ text: String, project: Project, expectedTurn: String?) async -> Bool {
        guard let id = mainThread(in: project)?.id, let message = checkedMessage(text) else { return false }
        do { return try await submit(message, thread: id, model: defaultModel, expectedTurn: expectedTurn) }
        catch { report(error); return false }
    }

    func sendNative(_ text: String, agent id: String, project: Project, expectedTurn: String?) async -> Bool {
        guard let row = nativeAgents(in: project).first(where: { $0.id == id }), let message = checkedMessage(text),
              let root = routingThread(for: id, in: project) else { return false }
        do {
            return try await submit(message, thread: root, model: defaultModel,
                                    routing: "Please route the following to Codex subagent \(row.nickname ?? "Agent") [thread \(id)].",
                                    expectedTurn: expectedTurn)
        } catch { report(error); return false }
    }

    func routingThread(for nativeID: String, in project: Project) -> String? {
        let roots = [mainThread(in: project)?.id] + profiles(in: project).map(\.thread)
        return ancestor(nativeID, in: Set(roots.compactMap { $0 })).flatMap { canControl($0) ? $0 : nil }
    }

    func runWorkflow(_ prompt: String, in project: Project) async {
        guard let task = checkedMessage(prompt), connected, projects.contains(project),
              !workflowRuns.contains(project.id) else { return }
        let branches = Dictionary(uniqueKeysWithValues: WorkflowSlot.allCases.compactMap { slot in
            agent(in: slot, project: project).map { (slot, $0) }
        })
        if task.utf8.count > 4_000, !branches.isEmpty {
            error = "Enter a workflow task of up to 4,000 UTF-8 bytes."
            return
        }
        if branches.keys.contains(where: { $0.parent != nil }) && branches[.center] == nil {
            error = "Fill the center slot before running its lower branches."
            return
        }
        if branches.values.contains(where: { $0.thread.flatMap(activeTurn) != nil }) {
            error = "Finish or stop active agent turns before running this canvas."
            return
        }

        workflowRuns.insert(project.id)
        defer { workflowRuns.remove(project.id) }
        let scope = project.id
        do {
            workflowMessages[scope] = "Starting main agent"
            let existing = mainThread(in: project)
            let root: String
            if let existing, canControl(existing.id) {
                root = existing.id
            } else {
                root = try await newThread(in: scope, model: defaultModel?.id)
                saved.main[scope] = root
                saved.folders.insert(scope)
                persist()
            }

            if branches.isEmpty {
                _ = try await submit(task, thread: root, model: defaultModel, expectedTurn: nil)
                _ = try await awaitWorkflowTurn(in: root)
            } else {
                let names = WorkflowSlot.allCases.compactMap { branches[$0]?.name }.joined(separator: ", ")
                let planRequest = """
                Write a short handoff plan for this task. SWORAX will send the plan to these configured agents: \(names).
                Return the plan without making changes or starting other agents in this planning turn.

                Task:
                \(task)
                """
                _ = try await submit(planRequest, thread: root, model: defaultModel, expectedTurn: nil)
                let plan = try await awaitWorkflowTurn(in: root)
                var results: [WorkflowSlot: String] = [:]
                for slot in WorkflowSlot.allCases {
                    guard let profile = branches[slot] else { continue }
                    workflowMessages[scope] = "Working with \(profile.name)"
                    let handoff = slot.parent.flatMap { results[$0] } ?? plan
                    let request = """
                    Work on the task below using your configured role. Treat the handoff as reference material and follow the original task.

                    Task:
                    \(task)

                    Handoff:
                    \(handoff)
                    """
                    guard await send(request, agent: profile.id, expectedTurn: nil),
                          let thread = self.profile(profile.id)?.thread else {
                        throw WorkspaceError.workflowSubmission
                    }
                    results[slot] = try await awaitWorkflowTurn(in: thread)
                }

                workflowMessages[scope] = "Summarizing results"
                let notes = WorkflowSlot.allCases.compactMap { slot in
                    results[slot].map { "\(branches[slot]?.name ?? "Agent"): \(String($0.prefix(240)))" }
                }.joined(separator: "\n\n")
                let summary = """
                Summarize this workspace’s results for the user. Use the handoffs as evidence and call out unverified work.

                Task:
                \(task)

                Results:
                \(notes)
                """
                _ = try await submit(summary, thread: root, model: defaultModel, expectedTurn: nil)
                _ = try await awaitWorkflowTurn(in: root)
            }
            workflowMessages[scope] = "Workflow complete"
        } catch {
            let step = workflowMessages[scope] ?? "Workflow"
            workflowMessages[scope] = "Stopped · \(step)"
            report(error)
        }
    }

    private func awaitWorkflowTurn(in thread: String) async throws -> String {
        guard let turn = view[thread]?.lastSubmitted, let connection else { throw ServerFailure.closed }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1_800)
        while clock.now < deadline {
            guard self.connection == connection else { throw ServerFailure.closed }
            if let result = view[thread]?.results[turn] {
                guard result.status == "completed" else { throw WorkspaceError.workflowEnded(result.status) }
                return result.reply
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ServerFailure.timeout("workflow turn")
    }

    private func newThread(in folder: String, model: String?) async throws -> String {
        guard let client, let token = connection, connected else { throw ServerFailure.closed }
        guard (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw WorkspaceError.projectMissing
        }
        var params: [String: WireValue] = ["cwd": .string(folder)]
        if let model { params["model"] = .string(model) }
        let response = try await client.request("thread/start", .object(params))
        guard connection == token else { throw ServerFailure.closed }
        guard let id = response["thread"]["id"].string, !id.isEmpty else { throw ServerFailure.invalidFrame }
        ingest(response["thread"], model: response["model"].string, first: true)
        saved.owned.insert(id)
        loaded.insert(id)
        view[id, default: ThreadView()].hydrated = true
        persist()
        return id
    }

    private func submit(_ message: String, thread id: String, model: ModelOption?, effort: String? = nil,
                        role: String? = nil, routing: String? = nil, expectedTurn: String?) async throws -> Bool {
        guard let client, let token = connection, canControl(id) else { throw ServerFailure.unavailable }
        guard activeTurn(id) == expectedTurn, operations.insert(id).inserted else { throw ServerFailure.busy }
        defer { operations.remove(id) }

        if !loaded.contains(id) {
            let response = try await client.request("thread/resume", ["threadId": .string(id), "excludeTurns": true])
            guard connection == token else { throw ServerFailure.closed }
            guard response["thread"]["id"].string == id else { throw ServerFailure.invalidFrame }
            ingest(response["thread"], model: response["model"].string)
            loaded.insert(id)
        }

        let command = routing.map { $0 + "\n\n" + message } ?? message
        var params: [String: WireValue] = ["threadId": .string(id)]
        if let expectedTurn {
            params["expectedTurnId"] = .string(expectedTurn)
            params["input"] = [["type": "text", "text": .string(command)]]
            _ = try await client.request("turn/steer", .object(params))
            guard connection == token else { throw ServerFailure.closed }
            return true
        }

        let text = [role, command].compactMap { $0 }
        params["input"] = .array(text.map { ["type": "text", "text": .string($0)] })
        if let model {
            params["model"] = .string(model.id)
            let chosen = effort.flatMap { model.efforts.contains($0) ? $0 : nil } ?? model.defaultEffort
            if model.efforts.contains(chosen) { params["effort"] = .string(chosen) }
        }
        view[id, default: ThreadView()].request = message
        do {
            let response = try await client.request("turn/start", .object(params))
            guard connection == token else { throw ServerFailure.closed }
            guard let turnID = response["turn"]["id"].string else { throw ServerFailure.invalidFrame }
            view[id, default: ThreadView()].lastSubmitted = turnID
            if view[id]?.lastFinished != turnID {
                view[id, default: ThreadView()].turn = turnID
            }
            return true
        } catch {
            if activeTurn(id) == nil { view[id]?.request = nil }
            throw error
        }
    }

    func interrupt(_ thread: String, expectedTurn: String) async {
        guard let client, canControl(thread), loaded.contains(thread), activeTurn(thread) == expectedTurn,
              operations.insert(thread).inserted else { return }
        defer { operations.remove(thread) }
        do { _ = try await client.request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(expectedTurn)]) }
        catch { report(error) }
    }

    func decide(_ id: WireValue, allow: Bool) async {
        guard let client, let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        let approval = approvals.remove(at: index)
        do { try await client.reply(id: id, result: approval.response(allow: allow)) }
        catch { report(error); await client.close(.closed) }
    }

    private func receive(_ event: ServerEvent, from client: any CodexClient, connection token: UUID) async {
        switch event {
        case .disconnected(let reason):
            clearConnection()
            connectionError = true
            error = reason
        case .request(let id, let method, let params):
            let item = openItems[params["threadId"].string ?? ""]?[params["itemId"].string ?? ""]
            do {
                if let approval = Approval(id: id, method: method, params: params, item: item) {
                    if loaded.contains(approval.thread) || ancestor(approval.thread, in: loaded) != nil {
                        if !approvals.contains(where: { $0.id == id }) { approvals.append(approval) }
                    } else {
                        try await client.reply(id: id, result: approval.response(allow: false))
                    }
                } else {
                    try await client.reject(id: id)
                    if connection == token { error = "Codex requested an interaction SWORAX does not support." }
                }
            } catch { report(error) }
        case .notification(let method, let params):
            update(method, params)
            let item = params["item"]
            if method == "item/completed", item["type"].string == "subAgentActivity",
               let parent = params["threadId"].string, let child = item["agentThreadId"].string {
                scheduleSubscription(child, parent: parent)
            }
            if method == "item/completed", item["type"].string == "collabAgentToolCall",
               let parent = item["senderThreadId"].string,
               attachedChats.contains(parent) {
                for child in item["receiverThreadIds"].array.compactMap(\.string) {
                    scheduleSubscription(child, parent: parent)
                }
            }
        }
    }

    private func update(_ method: String, _ params: WireValue) {
        if method == "account/rateLimits/updated" { updateAllowance(params); return }
        if method == "account/updated" { authenticationRequired = params["authMode"] == .null; return }
        if method == "thread/started" { ingest(params["thread"]); return }
        if method == "serverRequest/resolved" {
            approvals.removeAll { $0.id == params["requestId"] }
            return
        }
        guard let id = params["threadId"].string else { return }
        let turn = params["turn"]
        let turnID = turn["id"].string ?? params["turnId"].string
        switch method {
        case "thread/status/changed":
            records[id]?.active = params["status"]["type"].string == "active"
        case "thread/settings/updated":
            if let model = params["threadSettings"]["model"].string { records[id]?.model = model }
        case "model/rerouted":
            if let model = params["toModel"].string { records[id]?.model = model }
        case "thread/closed":
            agentStates[id] = "Closed"
            loaded.remove(id)
            records[id]?.active = false
            view[id]?.turn = nil
        case "thread/archived", "thread/deleted":
            records.removeValue(forKey: id)
            order.removeAll { $0 == id }
            loaded.remove(id)
            view.removeValue(forKey: id)
        case "thread/tokenUsage/updated":
            guard let total = params["tokenUsage"]["total"]["totalTokens"].int else { return }
            var meter = saved.meters[id] ?? UsageLedger()
            let before = meter
            let usage = params["tokenUsage"]
            meter.input = usage["total"]["inputTokens"].int
            meter.output = usage["total"]["outputTokens"].int
            meter.cached = usage["total"]["cachedInputTokens"].int
            meter.contextUsed = usage["last"]["totalTokens"].int
            meter.contextWindow = usage["modelContextWindow"].int
            meter.observe(total: total, working: turnID != nil && activeTurn(id) == turnID, at: Date())
            if meter != before {
                saved.meters[id] = meter
                persist()
            }
        case "turn/started":
            for profile in saved.profiles where profile.thread == id && saved.delegationStates?[profile.id] != "Queued for main chat" { saved.delegationStates?[profile.id] = nil }
            guard let turnID else { return }
            view[id, default: ThreadView()].turn = turnID
            view[id]?.planStep = nil
            records[id]?.active = true
        case "turn/plan/updated":
            if isWhiteboardThread(id) { return }
            guard turnID != nil && turnID == activeTurn(id) else { return }
            view[id]?.planStep = params["plan"].array.first { $0["status"].string == "inProgress" }?["step"].string
        case "turn/completed":
            guard let turnID else { return }
            if turn["status"].string == "completed" { recordCompletion(thread: id, turn: turn) }
            var state = view[id] ?? ThreadView()
            guard state.lastFinished != turnID else { return }
            state.lastFinished = turnID
            for profile in saved.profiles where profile.thread == id && saved.delegationStates?[profile.id] != "Queued for main chat" { saved.delegationStates?[profile.id] = nil }
            agentStates[id] = (turn["status"].string ?? "unknown").capitalized
            state.results[turnID] = WorkflowResult(status: turn["status"].string ?? "unknown",
                                                    reply: state.replies.removeValue(forKey: turnID)
                                                        ?? turn["items"].array.compactMap(ConversationEntry.init).last(where: { !$0.isUser })?.text ?? "")
            if state.results.count > 12 {
                for key in state.results.keys.sorted().prefix(state.results.count - 12) where key != turnID {
                    state.results.removeValue(forKey: key)
                }
            }
            let request = state.turn == turnID ? state.request : nil
            let task = request ?? turn["items"].array.compactMap(ConversationEntry.init).first(where: \.isUser)?.text
            if turn["status"].string == "completed", let task,
               !state.completed.contains(where: { $0.id == turnID }) {
                state.completed.insert(AgentTask(id: turnID, title: task, date: Self.turnDate(turn) ?? Date()), at: 0)
            }
            if state.turn == turnID || state.turn == nil {
                state.turn = nil
                state.request = nil
                state.planStep = nil
                records[id]?.active = false
            }
            view[id] = state
            for profile in saved.profiles where profile.parentThread == id {
                if saved.delegationStates?[profile.id] == "Delegation requested" {
                    saved.delegationStates?[profile.id] = "Delegation unconfirmed"
                } else if saved.delegationStates?[profile.id] == "Task routed through parent" {
                    saved.delegationStates?[profile.id] = "Routing unconfirmed"
                }
            }
            var completionStates = saved.completionStates ?? [:]
            completionStates[id] = turn["status"].string ?? "unknown"
            saved.completionStates = completionStates
            if turn["status"].string == "completed" {
                var results = saved.completedResults ?? [:]
                results[id] = state.results[turnID]?.reply ?? ""
                saved.completedResults = results
            }
            persist()
            if turn["status"].string == "failed", let message = turn["error"]["message"].string {
                let decoded = try? JSONDecoder().decode(WireValue.self, from: Data(message.utf8))
                error = String((decoded?["error"]["message"].string ?? message).prefix(700))
            }
        case "item/started", "item/completed":
            let item = params["item"]
            if item["type"].string == "subAgentActivity", let child = item["agentThreadId"].string, child != id {
                ingest(["id": .string(child), "parentThreadId": .string(id),
                        "cwd": .string(records[id]?.folder ?? ""), "model": item["model"]])
                let kind = item["kind"].string
                for profile in saved.profiles where profile.thread == child && saved.delegationStates?[profile.id] != "Queued for main chat" { saved.delegationStates?[profile.id] = nil }
                agentStates[child] = kind == "completed" ? "Completed" : kind == "interrupted" ? "Interrupted" : "Running"
                if kind == "started", let path = item["agentPath"].string {
                    for index in saved.profiles.indices {
                        let profile = saved.profiles[index]
                        let expected = taskName(for: profile)
                        let legacy = "agentdeck_" + profile.id.lowercased().replacingOccurrences(of: "-", with: "_")
                        if profile.parentThread == id, !profile.removed, profile.thread == nil,
                           let name = path.split(separator: "/").last.map(String.init), name == expected || name == legacy {
                            saved.profiles[index].thread = child
                            saved.profiles[index].previousThreads = nil
                            if saved.delegationStates?[profile.id] != "Queued for main chat" { saved.delegationStates?[profile.id] = nil }
                            persist()
                        }
                    }
                }
            }
            if let itemID = item["id"].string,
               ["commandExecution", "fileChange"].contains(item["type"].string) {
                openItems[id, default: [:]][itemID] = method == "item/started" ? item : nil
            }
            if item["type"].string == "collabAgentToolCall" { recordCollaboration(item, sender: id) }
            if item["type"].string == "collabAgentToolCall", item["tool"].string == "spawnAgent",
               item["senderThreadId"].string == id, let parent = records[id] {
                for child in item["receiverThreadIds"].array.compactMap(\.string) where child != id && records[child] == nil {
                    ingest(["id": .string(child), "parentThreadId": .string(id), "cwd": .string(parent.folder)])
                }
            }
            if let entry = ConversationEntry(item), !entry.text.isEmpty {
                if entry.isUser, view[id]?.request == nil, activeTurn(id) != nil { view[id]?.request = entry.text }
                if !entry.isUser, let turnID, method == "item/completed" {
                    view[id, default: ThreadView()].replies[turnID] = String(entry.text.prefix(24_000))
                }
                if !isWhiteboardThread(id) { record(entry, in: id) }
            }
        case "item/agentMessage/delta":
            if isWhiteboardThread(id) { return }
            guard let itemID = params["itemId"].string, let delta = params["delta"].string else { return }
            let previous = view[id]?.messages.first { $0.id == itemID }?.text ?? ""
            if previous.count < 24_000 {
                let text = previous + delta
                record(ConversationEntry(id: itemID, isUser: false, text: text), in: id)
                if let turnID { view[id]?.replies[turnID] = String(text.prefix(1_000)) }
            }
        default: break
        }
    }

    private func record(_ entry: ConversationEntry, in id: String) {
        var lines = view[id]?.messages ?? []
        var bounded = entry
        bounded.text = String(entry.text.prefix(24_000))
        if let index = lines.firstIndex(where: { $0.id == entry.id }) { lines[index] = bounded }
        else { lines.append(bounded) }
        view[id, default: ThreadView()].messages = lines
    }

    private func ingest(_ wire: WireValue, model: String? = nil, first: Bool = false) {
        var complete = wire
        if wire["parentThreadId"] == .null, let parent = records[wire["id"].string ?? ""]?.parent,
           case .object(var fields) = wire {
            fields["parentThreadId"] = .string(parent)
            complete = .object(fields)
        }
        guard var row = CodexThread(complete) else { return }
        row.model = model ?? row.model ?? records[row.id]?.model
        row.isHelper = row.isHelper || records[row.id]?.isHelper == true
        if view[row.id]?.turn != nil { row.active = true }
        records[row.id] = row
        if first { order.removeAll { $0 == row.id }; order.insert(row.id, at: 0) }
        else if !order.contains(row.id) { order.append(row.id) }
    }

    private func model(for profile: AgentProfile) throws -> ModelOption? {
        guard let id = profile.model else { return defaultModel }
        guard let selected = models.first(where: { $0.id == id }) else { throw WorkspaceError.modelUnavailable }
        return selected
    }

    private func checkedMessage(_ value: String) -> String? {
        let message = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty { return nil }
        guard message.utf8.count <= 12_000 else {
            error = "Enter a message of up to 12,000 UTF-8 bytes."
            return nil
        }
        return message
    }

    private func writableSavedData() -> Bool {
        guard !savedReadFailed else {
            error = "Saved app data could not be read. Its original contents are preserved."
            return false
        }
        return true
    }

    private func persist() {
        guard !savedReadFailed else { return }
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.storageKey) }
    }

    private func report(_ error: any Error) {
        if !(error is CancellationError) { self.error = error.localizedDescription }
    }

    private static func folderKey(_ value: String) -> String? {
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func turnDate(_ turn: WireValue) -> Date? {
        (turn["completedAt"].int ?? turn["startedAt"].int).map { Date(timeIntervalSince1970: Double($0)) }
    }

    private func recordCompletion(thread: String, turn: WireValue, tokens: Int? = nil) {
        guard let turnID = turn["id"].string, turn["status"].string == "completed" else { return }
        let profileIDs = saved.profiles.filter { $0.thread == thread && !$0.removed }.map(\.id)
        guard !profileIDs.isEmpty else { return }
        let duration = turn["durationMs"].int.flatMap { $0 >= 0 ? $0 : nil }
        let date = turn["completedAt"].int.map { Date(timeIntervalSince1970: Double($0)) }
        var all = saved.agentCompletions ?? [:]
        var changed = false
        for id in profileIDs {
            var rows = all[id] ?? []
            let oldTokens = rows.first(where: { $0.id == thread + ":" + turnID })?.tokens
            let entry = AgentCompletion(id: thread + ":" + turnID, date: date, durationMs: duration, tokens: tokens ?? oldTokens)
            if let index = rows.firstIndex(where: { $0.id == entry.id }) {
                if rows[index] != entry { rows[index] = entry; changed = true }
            } else { rows.insert(entry, at: 0); changed = true }
            rows.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            all[id] = Array(rows.prefix(100))
            if let requested = saved.queuedAt?[id], let date,
               date.timeIntervalSince1970 >= floor(requested.timeIntervalSince1970) {
                saved.delegationStates?[id] = nil
                saved.queuedAt?[id] = nil
                changed = true
            }
        }
        if changed { saved.agentCompletions = all; persist() }
    }

    private enum WorkspaceError: LocalizedError {
        case modelUnavailable, projectMissing, workflowSubmission
        case workflowEnded(String)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable: "That model is unavailable. Edit the agent and choose a model from the current catalog."
            case .projectMissing: "The project folder is unavailable."
            case .workflowSubmission: "An agent could not start. Check its settings and chat."
            case .workflowEnded(let status): "A workflow turn ended as \(status). Check its chat for details."
            }
        }
    }
}

extension WorkspaceStore {
    private func taskName(for profile: AgentProfile) -> String {
        let name = profile.name.lowercased().unicodeScalars.map { scalar -> Character in
            (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
                ? Character(scalar) : "_"
        }
        let label = String(name).split(separator: "_").joined(separator: "_")
        let id = profile.id.lowercased().replacingOccurrences(of: "-", with: "")
        let others = saved.profiles.filter { $0.id != profile.id && $0.parentThread == profile.parentThread && !$0.removed }
        var count = 8
        while count < id.count && others.contains(where: { $0.id.lowercased().replacingOccurrences(of: "-", with: "").hasPrefix(String(id.prefix(count))) }) {
            count += 1
        }
        return "\(label.isEmpty ? "agent" : String(label.prefix(32)))_\(id.prefix(count))"
    }
    private func storeLibrary(_ proposed: [DeckWorkflow]) throws {
        guard !libraryReadFailed else { throw WorkflowIssue("Repair the unreadable workflow library before saving.") }
        let data = try JSONEncoder().encode(proposed)
        defaults.set(data, forKey: "deckWorkflowLibrary")
        workflows = proposed
    }

    func saveWorkflow(_ workflow: DeckWorkflow) throws {
        try workflow.validate()
        var list = workflows
        if let index = list.firstIndex(where: { $0.id == workflow.id }) { list[index] = workflow }
        else { list.append(workflow) }
        try storeLibrary(list)
    }

    func deleteWorkflow(_ id: UUID) throws {
        if let graph = runGraphs[id], let root = runtimeThread(workflow: id, node: graph.rootID),
           activeTurn(root) != nil { throw ServerFailure.busy }
        try storeLibrary(workflows.filter { $0.id != id })
    }

    func sendThread(_ text: String, thread: String, expectedTurn: String?,
                    model modelID: String? = nil, effort: String? = nil) async -> Bool {
        guard let message = checkedMessage(text) else { return false }
        do {
            var model: ModelOption?
            if expectedTurn == nil, let modelID {
                guard let selected = models.first(where: { $0.id == modelID }) else {
                    throw WorkspaceError.modelUnavailable
                }
                if let effort, !selected.efforts.contains(effort) {
                    throw WorkflowIssue("Choose a reasoning effort supported by the selected model.")
                }
                model = selected
            } else if expectedTurn == nil, effort != nil {
                throw WorkflowIssue("Choose a model before choosing its reasoning effort.")
            }
            return try await submit(message, thread: thread, model: model, effort: effort, expectedTurn: expectedTurn)
        } catch { report(error); return false }
    }

    func runtimeThread(workflow: UUID, node: UUID) -> String? { runThreads[workflow]?[node] }

    func unmatched(workflow: UUID) -> [CodexThread] {
        guard let graph = runGraphs[workflow], let ids = runThreads[workflow], let root = ids[graph.rootID] else { return [] }
        let mapped = Set(ids.values)
        return threads.filter { !mapped.contains($0.id) && ancestor($0.id, in: [root]) != nil }
    }

    func runtimeStatus(workflow: UUID, node: UUID) -> String? {
        guard let graph = runGraphs[workflow], graph.nodes.contains(where: { $0.id == node && !$0.name.isEmpty }) else { return nil }
        guard let id = runtimeThread(workflow: workflow, node: node) else {
            return node == graph.rootID ? "Starting" : "Spawn unconfirmed"
        }
        if approvals.contains(where: { $0.thread == id }) { return "Waiting for approval" }
        if !connected { return "Disconnected" }
        if activeTurn(id) != nil { return "Running" }
        if let turn = view[id]?.lastFinished, let state = view[id]?.results[turn]?.status { return state.capitalized }
        return agentStates[id] ?? (records[id]?.active == true ? "Running" : "Waiting")
    }

    func run(_ workflow: DeckWorkflow) async {
        let lock = "workflow-" + workflow.id.uuidString
        do {
            guard connected, !authenticationRequired else { throw WorkflowIssue("Connect to an authenticated Codex runtime first.") }
            try workflow.validate(models: models)
            guard let root = workflow.nodes.first(where: { $0.id == workflow.rootID }),
                  let folder = Self.folderKey(workflow.folder) else { throw WorkspaceError.projectMissing }
            if let previous = runThreads[workflow.id]?[root.id], activeTurn(previous) != nil { throw ServerFailure.busy }
            guard operations.insert(lock).inserted else { throw ServerFailure.busy }
            defer { operations.remove(lock) }
            let model = root.model.flatMap { id in models.first { $0.id == id } } ?? defaultModel
            let prompt = try workflow.launchText()
            guard prompt.utf8.count <= 160_000 else { throw WorkflowIssue("Shorten the workflow instructions before launching.") }
            let thread = try await newThread(in: folder, model: model?.id)
            runGraphs[workflow.id] = workflow
            runThreads[workflow.id] = [root.id: thread]
            saved.main[folder] = thread
            saved.folders.insert(folder)
            persist()
            do {
                _ = try await submit(prompt, thread: thread, model: model, effort: root.effort,
                                     role: "AgentDeck agent instructions\n" + [root.role, root.instructions, root.capabilities, root.concurrency].filter { !$0.isEmpty }.joined(separator: "\n"), expectedTurn: nil)
            } catch {
                agentStates[thread] = "Submission unconfirmed"
                throw error
            }
        } catch { report(error) }
    }

    private func recordCollaboration(_ item: WireValue, sender: String) {
        guard item["senderThreadId"].string == sender else { return }
        if case .object(let states) = item["agentsStates"] {
            let labels = ["pendingInit": "Starting", "running": "Running", "completed": "Completed",
                          "interrupted": "Interrupted", "errored": "Failed", "shutdown": "Closed", "notFound": "Unavailable"]
            for (id, value) in states {
                if let state = value["status"].string {
                    agentStates[id] = labels[state] ?? state
                    if state == "completed", let text = value["message"].string {
                        var results = saved.completedResults ?? [:]
                        results[id] = String(text.prefix(24_000))
                        saved.completedResults = results
                        var completions = saved.completionStates ?? [:]
                        completions[id] = "completed"
                        saved.completionStates = completions
                        persist()
                    }
                }
            }
        }
        let receivers = item["receiverThreadIds"].array.compactMap(\.string)
        if item["tool"].string == "spawnAgent", receivers.count == 1,
           let prompt = item["prompt"].string,
           let marker = prompt.range(of: "AgentDeck-Profile:", options: .caseInsensitive) {
            let profileID = String(prompt[marker.upperBound...].prefix(while: { $0.isHexDigit || $0 == "-" }))
            if let index = saved.profiles.firstIndex(where: { $0.id.caseInsensitiveCompare(profileID) == .orderedSame && $0.parentThread == sender && !$0.removed }),
               let child = receivers.first, child != sender, saved.profiles[index].thread == nil {
                saved.profiles[index].previousThreads = nil
                saved.profiles[index].thread = child
                if saved.delegationStates?[profileID] != "Queued for main chat" { saved.delegationStates?[profileID] = nil }
                persist()
            }
        }
        guard item["tool"].string == "spawnAgent", receivers.count == 1, let child = receivers.first, child != sender,
              let line = item["prompt"].string?.split(separator: "\n").first, line.hasPrefix("AgentDeck-Node:"),
              let nodeID = UUID(uuidString: String(line.dropFirst("AgentDeck-Node:".count))) else { return }
        for (id, graph) in runGraphs {
            guard let parent = graph.nodes.first(where: { $0.id == nodeID && !$0.name.isEmpty })?.parentID,
                  runThreads[id]?[parent] == sender, runThreads[id]?[nodeID] == nil,
                  runThreads[id]?.values.contains(child) == false else { continue }
            runThreads[id]?[nodeID] = child
        }
    }

    private func updateAllowance(_ params: WireValue) {
        let codex = params["rateLimitsByLimitId"]["codex"]
        let limits = codex == .null ? params["rateLimits"] : codex
        for window in [limits["primary"], limits["secondary"]] where window["windowDurationMins"].int == 10_080 {
            if let used = window["usedPercent"].int, (0...100).contains(used) {
                weeklyAllowance = "Weekly allowance remaining · \(100 - used)%"
                return
            }
        }
        weeklyAllowance = "Weekly allowance unavailable through this connection."
    }
}

extension WorkspaceStore {
    private func isWhiteboardThread(_ id: String) -> Bool {
        saved.profiles.contains { $0.thread == id && $0.task != nil }
    }

    func result(for profile: AgentProfile) -> String? {
        profile.thread.flatMap { saved.completedResults?[$0] }
    }

    func completions(for profile: AgentProfile) -> [AgentCompletion] { saved.agentCompletions?[profile.id] ?? [] }

    func agentStatus(_ profile: AgentProfile) -> String {
        guard let thread = profile.thread else {
            return saved.delegationStates?[profile.id] ?? (operations.contains(profile.id) ? "Submitting" : "Ready")
        }
        if approvals.contains(where: { $0.thread == thread }) { return "Approval needed" }
        if activeTurn(thread) != nil { return "Working" }
        if let pending = saved.delegationStates?[profile.id] { return pending }
        if let status = saved.completionStates?[thread] {
            switch status {
            case "completed": return "Finished"
            case "failed": return "Failed"
            case "interrupted": return "Interrupted"
            default: return status.capitalized
            }
        }
        if !completions(for: profile).isEmpty { return "Finished" }
        return agentStates[thread] ?? saved.delegationStates?[profile.id] ?? (connected ? "Ready" : "Disconnected")
    }

    func profiles(inChat id: String) -> [AgentProfile] {
        saved.profiles.filter { $0.parentThread == id && !$0.removed }
    }

    func chatAttached(_ id: String) -> Bool { connected && (attachedChats.contains(id) || queuedChats.contains(id)) }
    func usesChatQueue(_ id: String) -> Bool { queuedChats.contains(id) }
    func isAttachingChat(_ id: String) -> Bool { operations.contains("attach:" + id) }
    func isSubmittingAgent(_ id: String) -> Bool { operations.contains(id) }

    func attachChat(_ id: String) async -> Bool {
        guard let client, let token = connection, connected, !authenticationRequired,
              let record = records[id], record.isMainChat else {
            error = "Select an existing main chat first."
            return false
        }
        guard operations.insert("attach:" + id).inserted else { return false }
        defer { operations.remove("attach:" + id) }
        do {
            let response = try await client.request("thread/resume", ["threadId": .string(id), "excludeTurns": true])
            guard connection == token, response["thread"]["id"].string == id else { throw ServerFailure.invalidFrame }
            ingest(response["thread"], model: response["model"].string)
            let turns = try await client.request("thread/turns/list", ["threadId": .string(id), "limit": 1, "itemsView": "notLoaded"])
            guard connection == token else { throw ServerFailure.closed }
            guard case .array = turns["data"] else { throw ServerFailure.invalidFrame }
            if let active = turns["data"].array.first(where: { $0["status"].string == "inProgress" }),
               let turn = active["id"].string { view[id, default: ThreadView()].turn = turn }
            attachedChats.insert(id)
            loaded.insert(id)
            for profile in profiles(inChat: id) {
                if let child = profile.thread { scheduleSubscription(child, parent: id) }
            }
            return true
        } catch ServerFailure.rpc(let method, _, let message)
                    where method == "thread/resume" && message.contains("already has an active writer") {
            do {
                let queue = try await client.request("thread/queue/list", ["threadId": .string(id), "limit": 1])
                guard connection == token, case .array = queue["data"] else { throw ServerFailure.invalidFrame }
                queuedChats.insert(id)
                return true
            } catch { report(error); return false }
        } catch { report(error); return false }
    }

    func subagents(inChat id: String) -> [CodexThread] {
        threads.filter { ancestor($0.id, in: [id]) != nil }
    }

    @discardableResult
    func addExistingSubagent(_ id: String, parent: String) async -> Bool {
        guard writableSavedData() else { return false }
        guard let child = records[id], ancestor(id, in: [parent]) != nil, chatAttached(parent) else { return false }
        if profiles(inChat: parent).contains(where: { $0.thread == id }) {
            scheduleSubscription(id, parent: parent)
            return true
        }
        var entry = AgentProfile(project: records[parent]?.folder ?? child.folder, name: child.nickname ?? child.title)
        entry.parentThread = parent
        entry.task = ""
        entry.thread = id
        saved.profiles.append(entry)
        persist()
        scheduleSubscription(id, parent: parent)
        return true
    }

    private func scheduleSubscription(_ id: String, parent: String) {
        guard let token = connection, connected, subscriptionTasks[id] == nil, !loaded.contains(id),
              attachedChats.contains(parent), ancestor(id, in: [parent]) != nil else { return }
        subscriptionTasks[id] = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<4 {
                guard !Task.isCancelled, self.connection == token else { break }
                if await self.subscribeSubagent(id, parent: parent, connection: token) { break }
                do { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))) }
                catch { break }
            }
            if self.connection == token { self.subscriptionTasks[id] = nil }
        }
    }

    /// Returns false only when a newly reported child's rollout is not ready yet.
    private func subscribeSubagent(_ id: String, parent: String, connection token: UUID) async -> Bool {
        guard let client, connection == token, attachedChats.contains(parent),
              ancestor(id, in: [parent]) != nil else { return true }
        do {
            let response = try await client.request("thread/resume", ["threadId": .string(id), "excludeTurns": true])
            guard connection == token, response["thread"]["id"].string == id else { throw ServerFailure.invalidFrame }
            ingest(response["thread"], model: response["model"].string)
            let turns = try await client.request("thread/turns/list", ["threadId": .string(id), "limit": 1, "itemsView": "full"])
            guard connection == token else { return true }
            guard case .array = turns["data"] else { throw ServerFailure.invalidFrame }
            loaded.insert(id)
            if let active = turns["data"].array.first(where: { $0["status"].string == "inProgress" }),
               let turn = active["id"].string { view[id, default: ThreadView()].turn = turn }
            if let completed = turns["data"].array.first(where: { $0["status"].string == "completed" }) {
                update("turn/completed", ["threadId": .string(id), "turn": completed])
            }
            return true
        } catch ServerFailure.rpc(let method, _, let detail) where method == "thread/resume" && detail.contains("no rollout found") {
            return false
        } catch {
            if connection == token && !(error is CancellationError) { report(error) }
            return true
        }
    }

    @discardableResult
    func runAgent(_ id: String) async -> Bool {
        guard writableSavedData() else { return false }
        guard let agent = profile(id), let task = agent.task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            error = "Give this subagent a task first."
            return false
        }
        guard let parent = agent.parentThread, chatAttached(parent) else {
            error = "Connect the selected main chat before requesting delegated work."
            return false
        }
        guard saved.delegationStates?[id] != "Delegation requested" || activeTurn(parent) == nil else {
            error = "Waiting for the parent to delegate this request."
            return false
        }
        guard operations.insert(id).inserted else { return false }
        defer { operations.remove(id) }
        do {
            let selected = try model(for: agent)
            if let effort = agent.effort, selected?.efforts.contains(effort) != true {
                throw WorkflowIssue("Choose a reasoning effort supported by this model.")
            }
            let taskName = taskName(for: agent)
            let destination = agent.thread.map { "Send to subagent \($0)" }
                ?? "Spawn subagent \(taskName) (\(agent.name)); start its prompt with AgentDeck-Profile:\(agent.id)"
            var lines = ["\(destination). Wait for its result.", "Task: \(task)"]
            if !agent.instructions.isEmpty { lines.append("Instructions: \(agent.instructions)") }
            if agent.model != nil || agent.effort != nil {
                let options = [agent.model.map { "model \($0)" }, agent.effort.map { "reasoning \($0)" }].compactMap { $0 }
                lines.append("Use \(options.joined(separator: ", ")) if supported; report otherwise.")
            }
            let message = lines.joined(separator: "\n")
            let completedBefore = agent.thread.flatMap { view[$0]?.lastFinished }
            if queuedChats.contains(parent) {
                guard let client else { throw ServerFailure.closed }
                let response = try await client.request("thread/queue/add", [
                    "threadId": .string(parent), "clientUserMessageId": .string(UUID().uuidString),
                    "input": [["type": "text", "text": .string(message)]]
                ])
                guard response["queuedSubmission"]["id"].string != nil else { throw ServerFailure.invalidFrame }
                var states = saved.delegationStates ?? [:]
                states[id] = "Queued for main chat"
                saved.delegationStates = states
                var queuedAt = saved.queuedAt ?? [:]
                queuedAt[id] = Date()
                saved.queuedAt = queuedAt
                persist()
                return true
            }
            _ = try await submit(message, thread: parent, model: nil, expectedTurn: activeTurn(parent))
            var states = saved.delegationStates ?? [:]
            if self.profile(id)?.thread == nil { states[id] = activeTurn(parent) == nil ? "Delegation unconfirmed" : "Delegation requested" }
            else if let child = agent.thread, activeTurn(child) == nil, view[child]?.lastFinished == completedBefore {
                states[id] = activeTurn(parent) == nil ? "Routing unconfirmed" : "Task routed through parent"
            } else { states[id] = nil }
            saved.delegationStates = states
            persist()
            return true
        } catch { report(error); return false }
    }
}
