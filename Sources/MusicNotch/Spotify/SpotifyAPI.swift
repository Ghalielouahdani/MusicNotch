import Foundation

/// Thin client for the Spotify Web API (2026 endpoints: `/playlists/{id}/items`, `/me/library`).
@MainActor
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

    struct Empty: Encodable {}

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String? }
        let error: Body
    }
}

// MARK: Response shapes

struct SpotifyPage<Item: Decodable>: Decodable {
    let items: [Item]
    let next: String?
}

struct SpotifyUser: Decodable {
    let id: String
    let display_name: String?
}

struct SpotifyPlaylist: Decodable {
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

/// One row of `GET /playlists/{id}/items` or `GET /me/tracks`.
/// Playlists moved the song from `track` to `item` in 2026; saved tracks still use `track`.
struct SpotifyPlaylistEntry: Decodable {
    struct Ref: Decodable {
        struct Artist: Decodable { let name: String? }
        let uri: String?
        let name: String?
        let duration_ms: Int?
        let artists: [Artist]?
    }

    let item: Ref?
    let track: Ref?

    var ref: Ref? { item ?? track }
    var uri: String? { ref?.uri }
}

struct SpotifySnapshot: Decodable {
    let snapshot_id: String
}

/// `GET /me/player/devices`.
struct SpotifyDevices: Decodable {
    struct Device: Decodable {
        let id: String?
        let is_active: Bool
        let is_restricted: Bool
        let name: String
        let type: String
    }

    let devices: [Device]
}

/// Body of `PUT /me/player/play`. Nil fields are left out.
struct SpotifyPlayRequest: Encodable {
    struct Offset: Encodable {
        var position: Int?
        var uri: String?
    }

    var context_uri: String
    var offset: Offset?
}
