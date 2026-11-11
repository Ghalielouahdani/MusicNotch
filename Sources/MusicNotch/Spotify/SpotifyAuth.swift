import AppKit
import CryptoKit
import Observation

nonisolated struct SpotifyTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

nonisolated enum SpotifyError: LocalizedError, Sendable {
    case notConnected
    case missingClientID
    case cancelled
    case timedOut
    case authorizationDenied(String)
    case server(String)
    case http(Int, String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notConnected: "Spotify isn't connected."
        case .missingClientID: "Paste your Spotify Client ID first."
        case .cancelled: "Connection cancelled."
        case .timedOut: "Spotify didn't answer in time. Try again."
        case .authorizationDenied(let reason): "Spotify said no (\(reason))."
        case .server(let message): message
        case .http(let status, let message): message.isEmpty ? "Spotify error \(status)." : message
        case .rateLimited: "Spotify is rate limiting requests. Try again in a minute."
        }
    }
}

/// Authorization Code with PKCE, redirecting to a loopback listener.
///
/// No client secret is involved, so the Client ID can live in UserDefaults.
/// Tokens go in the keychain.
@Observable
final class SpotifyAuth {
    enum Status: Equatable { case disconnected, connecting, connected }

    static let redirectPort: UInt16 = 47823
    static let redirectURI = "http://127.0.0.1:47823/callback"
    static let scopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "playlist-modify-private",
        "playlist-modify-public",
        "user-library-read",
        "user-library-modify",
    ]

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "spotifyClientID") }
    }
    private(set) var status: Status
    private(set) var lastError: String?

    @ObservationIgnored private var tokens: SpotifyTokens?
    @ObservationIgnored private var refreshTask: Task<SpotifyTokens, Error>?
    @ObservationIgnored private var server: LoopbackServer?

    init() {
        clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
        let stored = Keychain.read(SpotifyTokens.self, account: "spotify")
        tokens = stored
        status = stored == nil ? .disconnected : .connected
    }

    func connect() async {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            lastError = SpotifyError.missingClientID.localizedDescription
            return
        }
        guard status != .connecting else { return }
        status = .connecting
        lastError = nil

        let verifier = Self.randomString(length: 64)
        let state = Self.randomString(length: 24)
        var authorize = URLComponents(string: "https://accounts.spotify.com/authorize")!
        authorize.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]

        let server = LoopbackServer(port: Self.redirectPort, path: "/callback")
        self.server = server
        defer {
            server.stop()
            self.server = nil
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(300))
            server.finish(.failure(SpotifyError.timedOut))
        }
        defer { timeout.cancel() }

        do {
            try server.start()
            guard let url = authorize.url else { throw SpotifyError.server("Couldn't build the login link.") }
            NSWorkspace.shared.open(url)

            let callback = try await server.waitForCallback()
            let items = callback.queryItems ?? []
            if let error = items.first(where: { $0.name == "error" })?.value {
                throw SpotifyError.authorizationDenied(error)
            }
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                throw SpotifyError.server("Spotify sent back an unexpected answer. Try again.")
            }
            let tokens = try await requestTokens([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": clientID,
                "code_verifier": verifier,
            ], previous: nil)
            store(tokens)
            status = .connected
            NSApp.activate()
        } catch {
            status = tokens == nil ? .disconnected : .connected
            if case SpotifyError.cancelled = error { return }
            Log.spotify.error("connect failed: \(String(describing: error), privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func cancelConnect() {
        server?.finish(.failure(SpotifyError.cancelled))
    }

    func disconnect() {
        tokens = nil
        Keychain.delete(account: "spotify")
        status = .disconnected
    }

    /// A valid access token, refreshed when it's about to expire.
    func accessToken() async throws -> String {
        guard let tokens else { throw SpotifyError.notConnected }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        return try await refreshTokens().accessToken
    }

    /// Refreshes once even if several requests ask at the same time.
    @discardableResult
    func refreshTokens() async throws -> SpotifyTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw SpotifyError.notConnected }

        let clientID = clientID
        let task = Task {
            try await requestTokens([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": clientID,
            ], previous: current)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh
        } catch SpotifyError.server(let message) where message.localizedCaseInsensitiveContains("invalid") {
            // The refresh token was revoked: the user has to log in again.
            disconnect()
            throw SpotifyError.notConnected
        }
    }

    private func store(_ tokens: SpotifyTokens) {
        self.tokens = tokens
        Keychain.save(tokens, account: "spotify")
    }

    private func requestTokens(_ form: [String: String], previous: SpotifyTokens?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let failure = try? JSONDecoder().decode(TokenError.self, from: data)
            throw SpotifyError.server(failure.map { "\($0.error): \($0.error_description ?? "")" } ?? "Spotify error \(status).")
        }
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        return SpotifyTokens(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token ?? previous?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expires_in))
        )
    }

    private nonisolated struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private nonisolated struct TokenError: Decodable {
        let error: String
        let error_description: String?
    }

    // MARK: PKCE helpers

    private static func randomString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .joined(separator: "&")
    }
}
