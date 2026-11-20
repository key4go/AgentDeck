import Foundation

enum RecordedUsage {
    static func read(path: String, thread: String) -> [String: Int] {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let roots = ["sessions", "archived_sessions"].map {
            home.appendingPathComponent($0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        }
        guard roots.contains(where: { file.path.hasPrefix($0) }),
              file.lastPathComponent.hasSuffix("\(thread).jsonl"),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: file) else { return [:] }
        return parse(data, thread: thread)
    }

    static func parse(_ data: Data, thread: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for line in data.split(separator: 10) {
            guard let record = try? JSONDecoder().decode(WireValue.self, from: Data(line)),
                  record["type"].string == "token_usage_record" else { continue }
            let payload = record["payload"]
            guard payload["thread_id"].string == thread, let turn = payload["turn_id"].string,
                  let total = payload["turn_token_usage"]["total_tokens"].int, total >= 0 else { continue }
            result[turn] = total
        }
        return result
    }
}
