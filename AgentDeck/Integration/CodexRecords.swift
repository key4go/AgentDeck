import Foundation

struct CodexThread: Identifiable {
    let id: String
    let folder: String
    let parent: String?
    let nickname: String?
    let updatedAt: Date?
    let title: String
    var model: String?
    var active: Bool
    var isHelper: Bool
    var isMainChat: Bool { parent == nil && !isHelper }

    init?(_ value: WireValue) {
        guard let id = value["id"].string, !id.isEmpty else { return nil }
        self.id = id
        updatedAt = value["updatedAt"].int.map { Date(timeIntervalSince1970: Double($0)) }
        folder = value["cwd"].string ?? ""
        let source = value["source"]
        let agentSource = source["subAgent"] == .null ? source["subagent"] : source["subAgent"]
        let spawn = agentSource["thread_spawn"]
        parent = value["parentThreadId"].string ?? spawn["parent_thread_id"].string
        nickname = value["agentNickname"].string ?? spawn["agent_nickname"].string
        title = [value["name"].string, value["preview"].string]
            .compactMap { $0 }.first { !$0.isEmpty }.map { String($0.prefix(96)) } ?? "Main session"
        let classification = [source.string, source["custom"].string, value["threadSource"].string, value["agentRole"].string]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let normalizedTitle = title.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        isHelper = agentSource != .null || classification.contains("guardian") || classification.contains("subagent")
            || normalizedTitle.hasPrefix("guardian review")
        model = value["model"].string
        active = value["status"]["type"].string == "active"
    }
}

extension ConversationEntry {
    init?(_ item: WireValue) {
        guard let id = item["id"].string else { return nil }
        switch item["type"].string {
        case "userMessage":
            let parts = item["content"].array.compactMap { $0["text"].string }
            let count = parts.count > 1 && parts.first?.hasPrefix("AgentDeck agent instructions\n") == true ? 1 : 0
            self.init(id: id, isUser: true, text: String(parts.dropFirst(count).joined(separator: "\n").prefix(24_000)))
        case "agentMessage":
            self.init(id: id, isUser: false, text: item["text"].string ?? "")
        default:
            return nil
        }
    }
}

struct Approval: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case command = "Command execution", edits = "File changes", permissions = "Additional permissions"
    }

    let id: WireValue
    let thread: String
    let kind: Kind
    let details: String
    let reason: String?
    let canAllow: Bool

    init?(id: WireValue, method: String, params: WireValue, item: WireValue?) {
        guard let thread = params["threadId"].string else { return nil }
        self.id = id
        self.thread = thread
        reason = params["reason"].string.map(Self.visibleText)
        let offered = params["availableDecisions"]
        let canAccept = offered == .null || offered.array.contains("accept")
        switch method {
        case "item/commandExecution/requestApproval":
            kind = .command
            let network = params["networkApprovalContext"]
            if network != .null {
                details = Self.visibleText(network.formatted)
                canAllow = canAccept && network["host"].string != nil && network["protocol"].string != nil
            } else if let command = params["command"].string ?? item?["command"].string {
                details = Self.visibleText([params["cwd"].string ?? item?["cwd"].string, command].compactMap { $0 }.joined(separator: "\n"))
                canAllow = canAccept && !command.isEmpty
            } else {
                details = "Codex did not provide a command preview."
                canAllow = false
            }
        case "item/fileChange/requestApproval":
            kind = .edits
            let changes = item?["changes"].array ?? []
            let previews = changes.compactMap { change -> String? in
                guard let path = change["path"].string, !path.isEmpty,
                      let diff = change["diff"].string, !diff.isEmpty else { return nil }
                return path + "\n" + diff
            }
            let root = params["grantRoot"].string
            let preview = (previews + (root.map { ["Grant root: \($0)"] } ?? [])).joined(separator: "\n\n")
            details = Self.visibleText(String(preview.prefix(36_000)))
            canAllow = canAccept && !previews.isEmpty && previews.count == changes.count
                && preview.count <= 36_000 && root == nil
        case "item/permissions/requestApproval":
            kind = .permissions
            details = Self.visibleText(params["permissions"].formatted)
            canAllow = false
        default:
            return nil
        }
    }

    private static func visibleText(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if scalar == "\n" || scalar == "\t" { return String(scalar) }
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                return "\\u{\(String(scalar.value, radix: 16))}"
            }
            return String(scalar)
        }.joined()
    }

    func response(allow: Bool) -> WireValue {
        if kind == .permissions { return ["permissions": [:], "scope": "turn"] }
        return ["decision": allow && canAllow ? "accept" : "decline"]
    }
}

extension ModelOption {
    init?(_ value: WireValue) {
        guard let id = value["model"].string, let defaultEffort = value["defaultReasoningEffort"].string,
              value["hidden"].bool != true else { return nil }
        let efforts = value["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string }
        self.init(id: id, name: value["displayName"].string ?? id, efforts: efforts, defaultEffort: defaultEffort,
                  isDefault: value["isDefault"].bool == true)
    }
}

