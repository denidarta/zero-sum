import Foundation

public protocol Transport {
    func push(deviceId: String, ops: [Op]) async throws -> PushOutcome
    func pull(since: Int64) async throws -> PullPage
}

public enum TransportError: Error {
    case status(Int)
}

/// JSON over HTTP, the API in crates/server (`/sync/push`, `/sync/pull`).
public struct HTTPTransport: Transport {
    let base: URL
    let session: URLSession

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public func push(deviceId: String, ops: [Op]) async throws -> PushOutcome {
        struct Body: Encodable {
            let deviceId: String
            let ops: [Op]
            enum CodingKeys: String, CodingKey {
                case deviceId = "device_id"
                case ops
            }
        }
        var req = URLRequest(url: base.appendingPathComponent("sync/push"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(Body(deviceId: deviceId, ops: ops))
        return try await send(req)
    }

    public func pull(since: Int64) async throws -> PullPage {
        var c = URLComponents(url: base.appendingPathComponent("sync/pull"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "since", value: String(since))]
        return try await send(URLRequest(url: c.url!))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.timeoutInterval = 15  // fail fast so "offline" shows up quickly
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw TransportError.status(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
