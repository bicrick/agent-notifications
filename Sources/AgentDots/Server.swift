import Foundation
import Network

/// Minimal HTTP on 127.0.0.1: POST /event (AgentEvent JSON) and GET /state.
final class Server {
    private let listener: NWListener
    private let store: Store

    init(port: UInt16, store: Store) throws {
        self.store = store
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            self?.read(conn, Data())
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state {
                FileHandle.standardError.write(Data("agent-dots: cannot listen on \(port): \(e)\n".utf8))
                exit(1)
            }
        }
        listener.start(queue: .main)
    }

    private func read(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                MainActor.assumeIsolated { self.respond(conn, req) }
            } else if done || error != nil || buf.count > 1 << 20 {
                conn.cancel()
            } else {
                self.read(conn, buf)
            }
        }
    }

    private static func parse(_ buf: Data) -> (method: String, path: String, body: Data)? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }
        return (String(first[0]), String(first[1]), Data(body.prefix(length)))
    }

    @MainActor
    private func respond(_ conn: NWConnection, _ req: (method: String, path: String, body: Data)) {
        var status = "404 Not Found"
        var body = Data()
        switch (req.method, req.path) {
        case ("POST", "/event"):
            if let ev = try? JSONDecoder().decode(AgentEvent.self, from: req.body), store.apply(ev) {
                status = "204 No Content"
            } else {
                status = "400 Bad Request"
            }
        case ("GET", "/state"):
            status = "200 OK"
            body = store.json
        default: break
        }
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
