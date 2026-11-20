import Foundation
import CryptoKit

@main
struct FoundationCheck {
    static func main() {
        let recorded = """
        {"type":"token_usage_record","payload":{"thread_id":"child","turn_id":"turn1","turn_token_usage":{"total_tokens":100}}}
        {"type":"token_usage_record","payload":{"thread_id":"child","turn_id":"turn1","turn_token_usage":{"total_tokens":150}}}
        {"type":"token_usage_record","payload":{"thread_id":"other","turn_id":"turn1","turn_token_usage":{"total_tokens":999}}}
        {"type":"token_usage_record","payload":{"thread_id":"child","turn_id":"turn2","turn_token_usage":{"total_tokens":20}}}
        {"type":"token_usage_record","payload":{"thread_id":"child","turn_id":"bad","turn_token_usage":{"total_tokens":-1}}}
        malformed
        """
        precondition(RecordedUsage.parse(Data(recorded.utf8), thread: "child") == ["turn1": 150, "turn2": 20])
        precondition(RecordedUsage.read(path: "/etc/passwd", thread: "passwd").isEmpty)
        let folder = Project(folder: "/tmp/example")
        precondition(folder.id == "/tmp/example" && folder.name == "example")
        let original = AgentProfile(project: folder.id, name: "Reviewer", instructions: "Review carefully")
        let encoded = try! JSONEncoder().encode(original)
        precondition(try! JSONDecoder().decode(AgentProfile.self, from: encoded) == original)
        precondition(original.model == nil && original.thread == nil && !original.removed)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let monday = Date(timeIntervalSince1970: 1_700_438_400) // 2023-11-20 UTC
        let tuesday = monday.addingTimeInterval(86_400)
        let nextWeek = monday.addingTimeInterval(7 * 86_400)
        var usage = UsageLedger()
        precondition(usage.daily(at: monday, calendar: calendar) == nil)
        usage.observe(total: 100, working: true, at: monday, calendar: calendar)
        usage.observe(total: 100, working: false, at: tuesday, calendar: calendar)
        usage.observe(total: 140, working: true, at: tuesday, calendar: calendar)
        precondition(usage.session == 140 && usage.lifetime == 140)
        precondition(usage.daily(at: monday, calendar: calendar) == 100)
        precondition(usage.daily(at: tuesday, calendar: calendar) == 40)
        precondition(usage.weekly(at: tuesday, calendar: calendar) == 140)
        precondition(usage.weekly(at: nextWeek, calendar: calendar) == 0)
        usage.observe(total: 140, working: false, at: nextWeek, calendar: calendar)
        precondition(usage.daily(at: nextWeek, calendar: calendar) == 0)
        var graph = DeckWorkflow(folder: folder.folder)
        graph.nodes[0].task = "Check the sample"
        let catalog = [ModelOption(id: "test", name: "Test", efforts: ["low"], defaultEffort: "low")]
        graph.nodes[1].name = "Research"
        graph.nodes[1].instructions = "Read the sample."
        try! graph.validate(models: catalog)
        precondition(try! graph.launchText().contains(graph.nodes[1].id.uuidString))
        precondition(try! JSONDecoder().decode(DeckWorkflow.self, from: JSONEncoder().encode(graph)) == graph)
        graph.nodes[1].parentID = graph.nodes[1].id
        precondition((try? graph.validate()) == nil)
        let main = CodexThread(["id": "main", "name": "Feature work", "source": "cli"])!
        let guardian = CodexThread(["id": "guardian", "name": "Guardian review", "source": ["subAgent": "review"]])!
        let child = CodexThread(["id": "child", "source": ["subAgent": ["thread_spawn": ["parent_thread_id": "main", "agent_nickname": "Research"]]]])!
        let oldChild = CodexThread(["id": "old", "source": ["subagent": ["thread_spawn": ["parent_thread_id": "main"]]]])!
        precondition(main.isMainChat && !guardian.isMainChat && !child.isMainChat)
        precondition(child.parent == "main" && child.nickname == "Research" && oldChild.parent == "main")
        socketChecks()
        print("Foundation, dynamic graph and local WebSocket checks passed")
    }
    static func socketChecks() {
        var socket = LocalWebSocket()
        let upgrade = String(decoding: socket.upgrade, as: UTF8.self)
        let key = upgrade.components(separatedBy: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key: ") }!
            .dropFirst("Sec-WebSocket-Key: ".count)
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let response = Data("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
        precondition(try! socket.receive(response.prefix(7)).isEmpty)
        _ = try! socket.receive(response.dropFirst(7))
        precondition(socket.ready)
        let fragmented: [UInt8] = [0x01, 2, 65, 66, 0x80, 2, 67, 68, 0x89, 1, 80]
        let events = try! socket.receive(Data(fragmented))
        precondition(events.count == 2)
        if case .message(let data) = events[0] { precondition(data == Data("ABCD".utf8)) } else { preconditionFailure() }
        if case .ping(let data) = events[1] { precondition(data == Data("P".utf8)) } else { preconditionFailure() }
        for length in [0, 100, 126, 65_536] {
            let payload = Data(repeating: 65, count: length)
            let frame = LocalWebSocket.frame(payload)
            let header = length < 126 ? 2 : length <= 65_535 ? 4 : 10
            precondition(frame[1] & 0x80 != 0 && frame.count == length + header + 4)
            let mask = Array(frame[header..<header + 4])
            let decoded = Data(frame.dropFirst(header + 4).enumerated().map { $0.element ^ mask[$0.offset % 4] })
            precondition(decoded == payload)
            var serverFrame = Data([0x81, frame[1] & 0x7f])
            if header > 2 { serverFrame.append(frame[2..<header]) }
            serverFrame.append(payload)
            precondition(try! socket.receive(serverFrame.prefix(1)).isEmpty)
            let messages = try! socket.receive(serverFrame.dropFirst())
            if case .message(let text) = messages.first { precondition(text == payload) } else { preconditionFailure() }
        }
    }

}
