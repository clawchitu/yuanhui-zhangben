import Foundation
import Network

/// 单元测试用的本机 HTTP 桩（`NWListener`，任选端口）：记下每个请求，按 `handler` 回。
/// `delay` 让回包慢一点（测在途 / 并发）。
final class LocalStub: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: Data
        /// 请求头（名字小写）
        var headers: [String: String] = [:]
    }
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: String = "{}"
        /// 收下请求后不回包、直接断开（模拟服务器已处理、回包没到）
        var drop = false
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-stub")
    private let lock = NSLock()
    private var log: [Request] = []
    private let handler: @Sendable (Request) -> Reply
    private let delay: TimeInterval

    init(delay: TimeInterval = 0, handler: @escaping @Sendable (Request) -> Reply) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.handler = handler
        self.delay = delay
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { st in
            switch st { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            throw NSError(domain: "LocalStub", code: 1)
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var base: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { lock.withLock { log } }
    func count(_ path: String) -> Int { requests.filter { $0.path == path }.count }
    func stop() { listener.cancel() }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                lock.withLock { log.append(req) }
                let r = handler(req)
                queue.asyncAfter(deadline: .now() + delay) { if r.drop { c.cancel() } else { Self.send(c, r) } }
            } else if done || error != nil {
                c.cancel()
            } else {
                receive(c, buf)
            }
        }
    }

    private static func parse(_ buf: Data) -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var length = 0
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            headers[kv[0].lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
            if kv[0].lowercased() == "content-length" { length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), body: Data(body.prefix(length)), headers: headers)
    }

    private static func send(_ c: NWConnection, _ r: Reply) {
        let body = Data(r.body.utf8)
        var head = "HTTP/1.1 \(r.status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}
