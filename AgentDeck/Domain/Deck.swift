import Foundation

struct Project: Equatable, Identifiable, Codable {
    var id: String { folder }
    let folder: String
    var name: String { URL(fileURLWithPath: folder).lastPathComponent.isEmpty ? folder : URL(fileURLWithPath: folder).lastPathComponent }
}

struct AgentProfile: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    let project: String
    var name = ""
    var instructions = ""
    var model: String?
    var effort: String?
    var thread: String?
    var previousThreads: [String]?
    var removed = false
    var parentThread: String?
    var task: String?
    var positionX: Double?
    var positionY: Double?
}

struct ModelOption: Identifiable {
    let id: String
    let name: String
    let efforts: [String]
    let defaultEffort: String
    var isDefault = false
}

struct ConversationEntry: Identifiable {
    let id: String
    let isUser: Bool
    var text: String
}

struct AgentTask: Identifiable {
    let id: String
    let title: String
    let date: Date?
}

struct AgentCompletion: Codable, Identifiable, Equatable {
    let id: String
    let date: Date?
    let durationMs: Int?
    let tokens: Int?
}

struct UsageLedger: Codable, Equatable {
    private(set) var session: Int?
    private(set) var lifetime: Int?
    var input: Int?
    var output: Int?
    var cached: Int?
    var contextUsed: Int?
    var contextWindow: Int?
    private var days: [Date: Int] = [:]

    mutating func observe(total: Int, working: Bool, at time: Date, calendar: Calendar = .current) {
        guard total >= 0 else { return }
        let delta = max(0, total - (session ?? 0))
        session = max(session ?? 0, total)
        // The server replays cumulative counters on resume. Replay has no day attribution.
        lifetime = max(lifetime ?? 0, total)
        guard working && delta > 0 else { return }
        let day = calendar.startOfDay(for: time)
        days[day] = Self.add(days[day] ?? 0, delta)
    }

    mutating func includePrevious(_ previous: Self) {
        if let prior = previous.lifetime {
            lifetime = Self.add(lifetime ?? 0, prior)
        }
        if let prior = previous.input { input = Self.add(input ?? 0, prior) }
        if let prior = previous.output { output = Self.add(output ?? 0, prior) }
        if let prior = previous.cached { cached = Self.add(cached ?? 0, prior) }
        for (day, total) in previous.days {
            days[day] = Self.add(days[day] ?? 0, total)
        }
    }

    private static func add(_ left: Int, _ right: Int) -> Int {
        let (total, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int.max : total
    }

    func daily(at time: Date, calendar: Calendar = .current) -> Int? {
        guard lifetime != nil else { return nil }
        return days[calendar.startOfDay(for: time)] ?? 0
    }

    func weekly(at time: Date, calendar: Calendar = .current) -> Int? {
        guard lifetime != nil, let week = calendar.dateInterval(of: .weekOfYear, for: time) else { return nil }
        return days.reduce(0) { total, row in
            guard row.key >= week.start, row.key < week.end else { return total }
            return Self.add(total, row.value)
        }
    }
}

enum WorkflowSlot: String, Identifiable, CaseIterable, Codable {
    case left, center, right, lowerLeft, lowerRight

    var id: String { rawValue }

    var parent: Self? {
        switch self {
        case .lowerLeft, .lowerRight: .center
        default: nil
        }
    }
}

enum AgentPreset: String, Identifiable, CaseIterable {
    case research, development, design, qa, ops

    var id: String { rawValue }

    var name: String {
        switch self {
        case .research: "Research Agent"
        case .development: "Development Agent"
        case .design: "UI Agent"
        case .qa: "QA Agent"
        case .ops: "Ops Agent"
        }
    }

    var icon: String {
        switch self {
        case .research: "magnifyingglass"
        case .development: "chevron.left.forwardslash.chevron.right"
        case .design: "paintbrush.pointed"
        case .qa: "checkmark.shield"
        case .ops: "bolt"
        }
    }

    var instructions: String {
        switch self {
        case .research: "Investigate the task using relevant sources. Separate findings from assumptions and summarize the strongest evidence."
        case .development: "Implement the requested changes in the project. Start from existing conventions and run focused checks."
        case .design: "Review and improve the requested interface for usability, accessibility, and visual consistency."
        case .qa: "Verify the requested behavior with focused checks. Report reproducible failures and what remains unverified."
        case .ops: "Review the requested build or operational workflow. Prefer reversible changes and check the result."
        }
    }
}
