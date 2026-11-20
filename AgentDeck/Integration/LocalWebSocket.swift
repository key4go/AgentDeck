import Foundation
import CryptoKit

/// WebSocket framing for the CLI's byte-for-byte Unix socket proxy.
struct LocalWebSocket {
    enum Event { case message(Data), ping(Data), closed(Data) }
    private var buffer = Data()
    private var fragments: Data?
    private(set) var ready = false
    private let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    private let limit = 8 * 1024 * 1024

    var upgrade: Data {
        Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
    }

    static func frame(_ payload: Data, opcode: UInt8 = 1) -> Data {
        var data = Data([0x80 | opcode])
        if payload.count < 126 { data.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65_535 {
            data.append(0xfe)
            data.append(UInt8((payload.count >> 8) & 255))
            data.append(UInt8(payload.count & 255))
        } else {
            data.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        data.append(contentsOf: mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return data
    }

    mutating func receive(_ chunk: Data) throws -> [Event] {
        buffer.append(chunk)
        if !ready {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count < 16_384 else { throw ServerFailure.invalidFrame }
                return []
            }
            let headers = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let lines = headers.components(separatedBy: "\r\n")
            guard lines.first?.contains(" 101 ") == true,
                  lines.contains(where: { $0.lowercased().hasPrefix("sec-websocket-accept:") && $0.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces) == expected })
            else { throw ServerFailure.invalidFrame }
            buffer = Data(buffer[end.upperBound...])
            ready = true
        }
        var events: [Event] = []
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(10))
            let final = bytes[0] & 0x80 != 0
            let opcode = bytes[0] & 0x0f
            guard bytes[0] & 0x70 == 0, bytes[1] & 0x80 == 0 else { throw ServerFailure.invalidFrame }
            var header = 2
            var length = UInt64(bytes[1] & 0x7f)
            if length == 126 {
                guard buffer.count >= 4 else { break }
                length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
                header = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { break }
                length = bytes[2..<10].reduce(0) { ($0 << 8) | UInt64($1) }
                header = 10
            }
            guard length <= limit, opcode < 8 || (final && length <= 125) else { throw ServerFailure.invalidFrame }
            guard buffer.count >= header + Int(length) else { break }
            let payload = Data(buffer.dropFirst(header).prefix(Int(length)))
            buffer = Data(buffer.dropFirst(header + Int(length)))
            switch opcode {
            case 1:
                guard fragments == nil else { throw ServerFailure.invalidFrame }
                if final { events.append(.message(payload)) } else { fragments = payload }
            case 0:
                guard fragments != nil else { throw ServerFailure.invalidFrame }
                fragments?.append(payload)
                guard (fragments?.count ?? 0) <= limit else { throw ServerFailure.invalidFrame }
                if final { events.append(.message(fragments!)); fragments = nil }
            case 8: events.append(.closed(payload))
            case 9: events.append(.ping(payload))
            case 10: break
            default: throw ServerFailure.invalidFrame
            }
        }
        guard buffer.count <= limit + 10 else { throw ServerFailure.invalidFrame }
        return events
    }
}
