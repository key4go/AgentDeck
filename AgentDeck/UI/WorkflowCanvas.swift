import SwiftUI
import AppKit

struct CompactWhiteboard: View {
    let store: WorkspaceStore
    let project: Project
    let chatID: String
    @State private var editing: AgentProfile?
    @State private var dragging: [String: CGSize] = [:]

    private let cardSize = CGSize(width: 150, height: 108)

    var body: some View {
        VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Add agent").font(.caption.weight(.semibold)).foregroundStyle(DeckStyle.secondaryText)
                    ForEach(AgentPreset.allCases) { preset in
                        libraryItem(preset.name, icon: preset.icon, value: preset.rawValue)
                    }
                    libraryItem("Custom", icon: "plus", value: "custom")
                    Spacer(minLength: 8)
                    Menu("Existing") {
                        ForEach(store.subagents(inChat: chatID)) { child in
                            Button(child.nickname ?? child.title) { Task { _ = await store.addExistingSubagent(child.id, parent: chatID) } }
                        }
                        if store.subagents(inChat: chatID).isEmpty { Text("No reported subagents in this chat") }
                    }.font(.caption).foregroundStyle(DeckStyle.primaryText).disabled(!store.chatAttached(chatID))
                        .help("Add a reported subagent from this chat")
                }.padding(.horizontal, 12).padding(.vertical, 8)
            .background(DeckStyle.chrome)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.04)).frame(height: 1) }
            Divider().overlay(DeckStyle.line)
            GeometryReader { geometry in
                let profiles = store.profiles(inChat: chatID)
                let boardSize = CGSize(width: geometry.size.width, height: max(geometry.size.height, CGFloat((profiles.count + 2) / 3 * 120 + 12), (profiles.compactMap(\.positionY).max() ?? 0) + cardSize.height))
                ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    DeckStyle.background
                    if store.profiles(inChat: chatID).isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "square.on.square.dashed").font(.title2)
                            Text("Add an agent to get started")
                                .font(.system(size: 12, weight: .medium))
                            Text("Click or drag a preset above.")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                        let origin = position(for: profile, index: index, size: boardSize)
                        agentCard(profile)
                            .offset(x: origin.x + (dragging[profile.id]?.width ?? 0),
                                    y: origin.y + (dragging[profile.id]?.height ?? 0))
                            .gesture(DragGesture(minimumDistance: 4)
                                .onChanged { dragging[profile.id] = $0.translation }
                                .onEnded { value in
                                    var updated = store.profile(profile.id) ?? profile
                                    let point = clamp(CGPoint(x: origin.x + value.translation.width,
                                                              y: origin.y + value.translation.height), size: boardSize)
                                    updated.positionX = Double(point.x)
                                    updated.positionY = Double(point.y)
                                    store.save(updated)
                                    dragging[profile.id] = nil
                                })
                    }
                }
                .frame(width: boardSize.width, height: boardSize.height)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { values, location in
                    guard let value = values.first, value.hasPrefix("agentdeck:preset:") else { return false }
                    let raw = String(value.dropFirst("agentdeck:preset:".count))
                    guard raw == "custom" || AgentPreset(rawValue: raw) != nil else { return false }
                    let point = clamp(CGPoint(x: location.x - cardSize.width / 2, y: location.y - cardSize.height / 2), size: boardSize)
                    return addAgent(raw, at: point)
                }
                }
            }
        }
        .sheet(item: $editing) { profile in
            CompactAgentEditor(store: store, profile: profile)
        }
    }

    private func libraryItem(_ title: String, icon: String, value: String) -> some View {
        Button {
            _ = addAgent(value)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DeckStyle.primaryText.opacity(0.88))
                .frame(width: 30, height: 28)
        }
            .buttonStyle(GlassButtonStyle())
            .draggable("agentdeck:preset:" + value)
            .accessibilityLabel("Add \(title)")
            .help("Add or drag \(title) onto the board")
    }

    @discardableResult
    private func addAgent(_ raw: String, at point: CGPoint? = nil) -> Bool {
        var profile = AgentProfile(project: project.id)
        if let preset = AgentPreset(rawValue: raw) {
            profile.name = preset.name
            profile.instructions = preset.instructions
        } else {
            profile.name = "Custom Agent"
        }
        profile.parentThread = chatID
        profile.task = ""
        profile.positionX = point.map { Double($0.x) }
        profile.positionY = point.map { Double($0.y) }
        guard store.save(profile) else { return false }
        editing = profile
        return true
    }

    private func position(for profile: AgentProfile, index: Int, size: CGSize) -> CGPoint {
        clamp(CGPoint(x: profile.positionX ?? Double(12 + (index % 3) * 162),
                      y: profile.positionY ?? Double(12 + (index / 3) * 120)), size: size)
    }

    private func clamp(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), max(0, size.width - cardSize.width)),
                y: min(max(0, point.y), max(0, size.height - cardSize.height)))
    }

    private func agentCard(_ profile: AgentProfile) -> some View {
        let status = store.agentStatus(profile)
        let active = ["running", "working", "starting", "delegation requested", "task routed through parent"].contains(status.lowercased())
        return Button { editing = profile } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(DeckStyle.accent)
                    Text(profile.name).lineLimit(1).fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DeckStyle.primaryText)
                Text(profile.task?.isEmpty == false ? profile.task! : "Add a task")
                    .lineLimit(1).foregroundStyle(DeckStyle.secondaryText)
                HStack {
                    Circle().fill(statusColor(status)).frame(width: 6, height: 6)
                    Text(status).lineLimit(1)
                }.font(.system(size: 11)).foregroundStyle(DeckStyle.secondaryText)
                Text("\(store.tokens(for: profile).lifetime.map { $0.formatted() } ?? "—") tokens")
                    .font(.system(size: 11)).foregroundStyle(DeckStyle.secondaryText).lineLimit(1)
            }
            .font(.system(size: 12)).frame(width: cardSize.width - 20, height: cardSize.height - 20, alignment: .topLeading)
            .padding(10)
            .contentShape(Rectangle())
        }.buttonStyle(GlassButtonStyle(radius: 10, active: active))
            .accessibilityLabel("Edit \(profile.name)")
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running", "working", "starting", "delegation requested", "task routed through parent": DeckStyle.accent
        case "approval", "approval needed", "waiting for approval": .orange
        case "completed", "finished": .green
        case "failed": .red
        default: .gray
        }
    }
}

struct CompactAgentEditor: View {
    let store: WorkspaceStore
    @State var profile: AgentProfile
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    private var current: AgentProfile { store.profile(profile.id) ?? profile }
    private var activeTurn: String? { current.thread.flatMap { store.activeTurn($0) } }
    private var model: ModelOption? {
        store.models.first { $0.id == profile.model } ?? (profile.model == nil ? store.models.first(where: { $0.isDefault }) ?? store.models.first : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent details").font(.headline)
                Spacer()
                Button("Delete", role: .destructive) { confirmingDelete = true }
                Button("Done") { if store.save(profile) { dismiss() } }.keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Save agent and close")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if let parent = profile.parentThread {
                        Text("Main chat · \(store.thread(parent)?.title ?? parent)").font(.caption).foregroundStyle(.secondary)
                    }
                    if store.agentStatus(current) == "Delegation unconfirmed" {
                        Text("The parent has not reported a subagent for this request. Review its response in Codex.").font(.caption).foregroundStyle(.orange)
                    }
                    if let parent = profile.parentThread, store.usesChatQueue(parent) {
                        Text("Requests are queued for the main chat. Check Codex for the agent and its result.").font(.caption).foregroundStyle(.secondary)
                    }
                    field("Name", text: $profile.name)
                    Text("Task").font(.caption.weight(.semibold))
                    TextEditor(text: Binding(get: { profile.task ?? "" }, set: { profile.task = $0 }))
                        .font(.body).frame(height: 65).border(Color.gray.opacity(0.25))
                        .accessibilityLabel("Task")
                    DisclosureGroup("Instructions") {
                        TextEditor(text: $profile.instructions).font(.body).frame(height: 80).border(Color.gray.opacity(0.25))
                            .accessibilityLabel("Instructions")
                    }
                    if let child = current.thread, let actual = store.thread(child)?.model {
                        Text("Runtime model · \(actual)").font(.caption).foregroundStyle(.secondary)
                    }
                    let usage = store.tokens(for: current)
                    Text("Tokens: \(format(usage.lifetime)) total · \(format(usage.input)) input · \(format(usage.output)) output · \(format(usage.cached)) cached")
                        .font(.caption).foregroundStyle(.secondary)
                    if let result = store.result(for: current), !result.isEmpty {
                        HStack {
                            Text("Last completed output").font(.caption.weight(.semibold))
                            Spacer()
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) }
                        }
                        Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Color.gray.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Text("Task list").font(.caption.weight(.semibold))
                    if store.completions(for: current).isEmpty {
                        Text("No completed tasks yet").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.completions(for: current)) { completion in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                Spacer()
                                Text("Time taken: \(duration(completion.durationMs))")
                                Spacer()
                                Text("Tokens used: \(completion.tokens.map { $0.formatted() } ?? "—")")
                            }
                            Text(completion.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Date unavailable")
                                .foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }.padding(16)
            }
            Divider()
            modelControls.padding(.horizontal, 16).padding(.vertical, 7)
            Divider()
            HStack {
                if store.isSubmittingAgent(profile.id) {
                    ProgressView().controlSize(.small)
                    Text("Submitting…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(store.agentStatus(current)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let thread = current.thread, let turn = activeTurn, store.canControl(thread) {
                    Button("Interrupt") { Task { await store.interrupt(thread, expectedTurn: turn) } }
                } else {
                    Button("Delegate task") {
                        if store.save(profile) { Task { await store.runAgent(profile.id) } }
                    }.buttonStyle(.borderedProminent).tint(DeckStyle.accent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.isSubmittingAgent(profile.id) || !store.connected || profile.parentThread.map { !store.chatAttached($0) } != false || (profile.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }.frame(width: 460, height: 330)
            .confirmationDialog("Delete this agent?", isPresented: $confirmingDelete) {
                Button("Delete agent", role: .destructive) { if store.remove(profile.id) { dismiss() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes the agent from the board.") }
    }

    private var modelControls: some View {
        HStack(spacing: 12) {
            Picker("Model", selection: $profile.model) {
                Text("Default").tag(String?.none)
                ForEach(store.models) { Text($0.name).tag(Optional($0.id)) }
                if let id = profile.model, !store.models.contains(where: { $0.id == id }) {
                    Text("Unavailable · \(id)").tag(Optional(id))
                }
            }
            .onChange(of: profile.model) { _, _ in
                if let effort = profile.effort, model?.efforts.contains(effort) != true { profile.effort = nil }
            }
            .accessibilityLabel("Subagent model for next task")
            Picker("Effort", selection: $profile.effort) {
                Text("Default").tag(String?.none)
                ForEach(model?.efforts ?? [], id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                if let effort = profile.effort, model?.efforts.contains(effort) != true {
                    Text("Unavailable · \(effort)").tag(Optional(effort))
                }
            }.accessibilityLabel("Subagent reasoning effort for next task")
        }.font(.caption).help("Requested for future delegated work. Running agents keep their current settings.")
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            TextField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func format(_ number: Int?) -> String { number.map { $0.formatted() } ?? "—" }
    private func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        let seconds = milliseconds / 1_000
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}
