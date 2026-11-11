import Foundation
import Network

/// A one-shot HTTP listener on 127.0.0.1 that catches Spotify's OAuth redirect.
final class LoopbackServer {
    private let port: NWEndpoint.Port
    private let path: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URLComponents, Error>?
    private var pending: Result<URLComponents, Error>?

    init(port: UInt16, path: String) {
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
        self.path = path
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let error) = state { self?.finish(.failure(error)) }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Waits for the browser to hit the callback path.
    func waitForCallback() async throws -> URLComponents {
        try await withCheckedThrowingContinuation { continuation in
            if let pending {
                continuation.resume(with: pending)
                self.pending = nil
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(_ result: Result<URLComponents, Error>) {
        if let continuation {
            continuation.resume(with: result)
            self.continuation = nil
        } else if pending == nil {
            pending = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                guard let self else {
                    connection.cancel()
                    return
                }
                // "GET /callback?code=…&state=… HTTP/1.1"
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
                guard let components = URLComponents(string: "http://127.0.0.1" + target),
                      components.path == self.path else {
                    Self.respond(connection, status: "404 Not Found", body: "")
                    return
                }
                let succeeded = components.queryItems?.contains { $0.name == "code" } == true
                Self.respond(connection, status: "200 OK", body: Self.page(succeeded: succeeded))
                self.finish(.success(components))
            }
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(succeeded: Bool) -> String {
        let title = succeeded ? "Spotify is connected" : "Spotify wasn't connected"
        let detail = succeeded
            ? "You can close this tab and hover the notch to add songs to your playlists."
            : "Head back to MusicNotch settings and try again."
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>MusicNotch</title>
            <style>
            :root { color-scheme: light dark; }
            body { margin: 0; min-height: 100vh; display: grid; place-items: center;
                   font: 15px/1.5 -apple-system, system-ui, sans-serif; background: #000; color: #f5f5f7; }
            main { text-align: center; padding: 24px; }
            h1 { font-size: 28px; letter-spacing: -0.02em; line-height: 1.1; margin: 0 0 8px; }
            p { color: #a1a1a6; margin: 0; }
            </style></head>
            <body><main><h1>\(title)</h1><p>\(detail)</p></main></body></html>
            """
    }
}
