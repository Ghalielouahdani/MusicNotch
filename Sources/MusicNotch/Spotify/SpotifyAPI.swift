import Foundation

/// Thin client for the Spotify Web API (2026 endpoints: `/playlists/{id}/items`, `/me/library`).
final class SpotifyAPI {
    private let auth: SpotifyAuth
    private static let base = URL(string: "https://api.spotify.com/v1/")!

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    func get<Response: Decodable>(_ url: URL, as type: Response.Type = Response.self) async throws -> Response {
        let data = try await send("GET", url)
        return try JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    func send(_ method: String, _ url: URL, body: (some Encodable)? = Optional<Empty>.none) async throws -> Data {
        let payload = try body.map { try JSONEncoder().encode($0) }
        return try await send(method, url, payload: payload, retryOnUnauthorized: true)
    }

    private func send(_ method: String, _ url: URL, payload: Data?, retryOnUnauthorized: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let payload {
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return data
        case 401 where retryOnUnauthorized:
            try await auth.refreshTokens()
            return try await send(method, url, payload: payload, retryOnUnauthorized: false)
        case 429:
            throw SpotifyError.rateLimited
        default:
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message ?? ""
            throw SpotifyError.http(status, message)
        }
    }

    nonisolated struct Empty: Encodable {}

    private nonisolated struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String? }
        let error: Body
    }
}

// MARK: Response shapes

nonisolated struct SpotifyPage<Item: Decodable>: Decodable {
    let items: [Item]
    let next: String?
}

nonisolated struct SpotifyUser: Decodable {
    let id: String
    let display_name: String?
}

nonisolated struct SpotifyPlaylist: Decodable {
    struct Owner: Decodable { let id: String }
    struct Image: Decodable {
        let url: String
        let width: Int?
    }

    let id: String
    let name: String
    let collaborative: Bool?
    let owner: Owner?
    let snapshot_id: String?
    let images: [Image]?
}

/// One row of `GET /playlists/{id}/items`. The track moved from `track` to `item` in 2026.
nonisolated struct SpotifyPlaylistEntry: Decodable {
    struct Ref: Decodable { let uri: String? }
    let item: Ref?
    let track: Ref?

    var uri: String? { item?.uri ?? track?.uri }
}

nonisolated struct SpotifySnapshot: Decodable {
    let snapshot_id: String
}
