import Foundation

struct DeckNode: Codable, Equatable, Identifiable {
    var id = UUID()
    var parentID: UUID?
    var name = ""
    var role = ""
    var instructions = ""
    var task = ""
    var model: String?
    var effort: String?
    var concurrency = ""
    var capabilities = ""
}

struct DeckWorkflow: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Agent Workflow"
    var folder: String
    var nodes: [DeckNode]
    let rootID: UUID

    init(folder: String) {
        self.folder = folder
        let root = DeckNode(name: "Main Agent", role: "Main Agent", instructions: "Coordinate the workflow and summarize its results.")
        rootID = root.id
        let slots = (0..<3).map { _ in DeckNode(parentID: root.id) }
        nodes = [root] + slots + [DeckNode(parentID: slots[1].id), DeckNode(parentID: slots[1].id)]
    }

    func duplicated() -> Self {
        var copy = self
        copy.id = UUID()
        copy.name += " Copy"
        return copy
    }

    func validate(models: [ModelOption]? = nil) throws {
        func meaningful(_ string: String) -> Bool { !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard meaningful(name), nodes.count <= 512, Set(nodes.map(\.id)).count == nodes.count,
              let root = nodes.first(where: { $0.id == rootID }), root.parentID == nil, meaningful(root.name)
        else { throw WorkflowIssue("Choose a workflow name and a valid main agent. Workflows support up to 512 slots.") }
        let children = Dictionary(grouping: nodes, by: \.parentID)
        var queue = [root]
        var i = 0
        let defaultModel = models?.first(where: \.isDefault) ?? models?.first
        var inherited: [UUID: ModelOption] = [:]
        while i < queue.count {
            let node = queue[i]
            if let models, !node.name.isEmpty {
                guard meaningful(node.instructions) else { throw WorkflowIssue("Add instructions for \(node.name).") }
                guard let model = node.model.flatMap({ id in models.first { $0.id == id } }) ??
                        (node.model == nil ? node.parentID.flatMap { inherited[$0] } ?? defaultModel : nil)
                else { throw WorkflowIssue("Choose an available model for \(node.name).") }
                inherited[node.id] = model
                if let effort = node.effort, !model.efforts.contains(effort) { throw WorkflowIssue("Choose a supported reasoning effort for \(node.name).") }
            }
            let branch = children[node.id] ?? []
            if models != nil && node.name.isEmpty && branch.contains(where: { !$0.name.isEmpty }) {
                throw WorkflowIssue("Assign the empty parent slot before running its children.")
            }
            queue.append(contentsOf: branch)
            i += 1
        }
        guard queue.count == nodes.count else { throw WorkflowIssue("Every slot must connect to the main agent without a cycle.") }
        if models != nil && !meaningful(root.task) { throw WorkflowIssue("Enter a task for the main agent.") }
    }

    func launchText() throws -> String {
        let roles = nodes.filter { !$0.name.isEmpty && $0.id != rootID }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let task = nodes.first { $0.id == rootID }?.task ?? ""
        guard !roles.isEmpty else { return task }
        let assignments = String(decoding: try encoder.encode(roles), as: UTF8.self)
        return """
        \(task)

        Delegate the assignments below using native Codex subagents. The main agent ID is \(rootID).
        For each assignment, its specified parent should spawn it. Begin each spawn prompt with exactly
        AgentDeck-Node:<the assignment UUID> on a line by itself, followed by the actual task and instructions.
        Request each selected model and effort where supported, otherwise inherit from the parent.
        Honor the task, capability and concurrency preferences within existing permissions. Wait for results.
        Report any assignment or preference the runtime could not fulfill and summarize verified results.
        Assignments:
        \(assignments)
        """
    }
}

struct WorkflowIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DeckEvent: Identifiable {
    let id = UUID()
    let thread: String
    let detail: String
    let date = Date()
}
