import Foundation

/// Spotify playlists through the Web API.
///
/// Spotify has no "is this song in that playlist" endpoint, so each playlist's
/// track URIs are cached on disk and only re-fetched when its snapshot ID changes.
final class SpotifyLibrary: PlaylistProvider {
    static let likedSongsID = "spotify:liked-songs"

    let auth: SpotifyAuth
    private let api: SpotifyAPI
    private var userID: String?
    private var index: [Playlist.ID: CachedPlaylist]

    private nonisolated struct CachedPlaylist: Codable {
        var snapshotID: String
        var uris: Set<String>
    }

    init(auth: SpotifyAuth) {
        self.auth = auth
        api = SpotifyAPI(auth: auth)
        index = Self.loadIndex()
    }

    func playlists() async throws -> [Playlist] {
        let me = try await currentUserID()
        var result = [Playlist(id: Self.likedSongsID, name: MusicSource.spotify.favoritesName, kind: .favorites)]
        var next: URL? = api.url("me/playlists", query: [URLQueryItem(name: "limit", value: "50")])
        var pages = 0
        while let url = next, pages < 20 {
            let page = try await api.get(url, as: SpotifyPage<SpotifyPlaylist>.self)
            // Only playlists the user can edit.
            for playlist in page.items where playlist.owner?.id == me || playlist.collaborative == true {
                let cover = playlist.images?
                    .min { ($0.width ?? .max) < ($1.width ?? .max) }
                    .flatMap { URL(string: $0.url) }
                result.append(Playlist(
                    id: playlist.id, name: playlist.name, kind: .regular,
                    imageURL: cover, snapshotID: playlist.snapshot_id
                ))
            }
            next = page.next.flatMap(URL.init(string:))
            pages += 1
        }
        return result
    }

    func playlistsContaining(
        _ track: Track,
        among playlists: [Playlist],
        progress: (Set<Playlist.ID>) -> Void
    ) async throws -> Set<Playlist.ID> {
        var found: Set<Playlist.ID> = []
        if try await isLiked(track) {
            found.insert(Self.likedSongsID)
            progress(found)
        }
        for playlist in playlists where playlist.kind == .regular {
            try Task.checkCancellation()
            if try await uris(in: playlist).contains(track.id) {
                found.insert(playlist.id)
                progress(found)
            }
        }
        return found
    }

    func add(_ track: Track, to playlist: Playlist) async throws -> Playlist {
        if playlist.kind == .favorites {
            try await api.send("PUT", api.url("me/library", query: [URLQueryItem(name: "uris", value: track.id)]))
            return playlist
        }
        let data = try await api.send("POST", api.url("playlists/\(playlist.id)/items"), body: ["uris": [track.id]])
        return recordChange(in: playlist, response: data) { $0.insert(track.id) }
    }

    func remove(_ track: Track, from playlist: Playlist) async throws -> Playlist {
        if playlist.kind == .favorites {
            try await api.send("DELETE", api.url("me/library", query: [URLQueryItem(name: "uris", value: track.id)]))
            return playlist
        }
        let body = RemoveItems(items: [.init(uri: track.id)], snapshot_id: nil)
        let data = try await api.send("DELETE", api.url("playlists/\(playlist.id)/items"), body: body)
        return recordChange(in: playlist, response: data) { $0.remove(track.id) }
    }

    func canPlay(_ playlist: Playlist) -> Bool { true }

    func play(_ playlist: Playlist) async throws {
        let context = try await contextURI(for: playlist)
        try await AppleScriptRunner.shared.run(try PlayerScripts.spotifyPlay(context), cache: false)
    }

    func play(_ track: PlaylistTrack, in playlist: Playlist) async throws {
        let context = try await contextURI(for: playlist)
        try await AppleScriptRunner.shared.run(try PlayerScripts.spotifyPlay(track.trackID, inContext: context), cache: false)
    }

    func tracks(in playlist: Playlist, progress: ([PlaylistTrack]) -> Void) async throws -> [PlaylistTrack] {
        var tracks: [PlaylistTrack] = []
        let limit = URLQueryItem(name: "limit", value: "50")
        if playlist.kind == .favorites {
            try await collectTracks(from: api.url("me/tracks", query: [limit]), into: &tracks, progress: progress)
            return tracks
        }
        let fields = "next,items(item(uri,name,duration_ms,artists(name)),track(uri,name,duration_ms,artists(name)))"
        do {
            let url = api.url("playlists/\(playlist.id)/items", query: [limit, URLQueryItem(name: "fields", value: fields)])
            try await collectTracks(from: url, into: &tracks, progress: progress)
        } catch SpotifyError.http(400, _) {
            // In case the `fields` filter rejects the new key, fetch whole pages instead.
            tracks.removeAll()
            try await collectTracks(from: api.url("playlists/\(playlist.id)/items", query: [limit]), into: &tracks, progress: progress)
        }
        return tracks
    }

    func forgetAccount() {
        userID = nil
        index = [:]
        try? FileManager.default.removeItem(at: Self.indexURL)
    }

    // MARK: Private

    private nonisolated struct RemoveItems: Encodable {
        struct Item: Encodable { let uri: String }
        let items: [Item]
        let snapshot_id: String?
    }

    private func currentUserID() async throws -> String {
        if let userID { return userID }
        let user = try await api.get(api.url("me"), as: SpotifyUser.self)
        userID = user.id
        return user.id
    }

    /// What Spotify plays through: the playlist, or the user's Liked Songs collection.
    private func contextURI(for playlist: Playlist) async throws -> String {
        switch playlist.kind {
        case .favorites: "spotify:user:\(try await currentUserID()):collection"
        case .regular: "spotify:playlist:\(playlist.id)"
        }
    }

    /// Up to 2,000 songs, 50 per request, reported page by page.
    private func collectTracks(
        from url: URL,
        into tracks: inout [PlaylistTrack],
        progress: ([PlaylistTrack]) -> Void
    ) async throws {
        var next: URL? = url
        var pages = 0
        while let current = next, pages < 40 {
            try Task.checkCancellation()
            let page = try await api.get(current, as: SpotifyPage<SpotifyPlaylistEntry>.self)
            for entry in page.items {
                guard let ref = entry.ref, let uri = ref.uri, let name = ref.name else { continue }
                tracks.append(PlaylistTrack(
                    position: tracks.count,
                    trackID: uri,
                    title: name,
                    artist: (ref.artists ?? []).compactMap(\.name).joined(separator: ", "),
                    duration: TimeInterval(ref.duration_ms ?? 0) / 1000
                ))
            }
            progress(tracks)
            next = page.next.flatMap(URL.init(string:))
            pages += 1
        }
    }

    private func isLiked(_ track: Track) async throws -> Bool {
        let url = api.url("me/library/contains", query: [URLQueryItem(name: "uris", value: track.id)])
        return try await api.get(url, as: [Bool].self).first ?? false
    }

    private func uris(in playlist: Playlist) async throws -> Set<String> {
        if let cached = index[playlist.id], cached.snapshotID == playlist.snapshotID {
            return cached.uris
        }
        var uris = Set<String>()
        do {
            try await collectURIs(of: playlist, fields: "next,items(item(uri),track(uri))", into: &uris)
        } catch SpotifyError.http(400, _) {
            // In case the `fields` filter rejects the new key, fetch whole pages instead.
            uris.removeAll()
            try await collectURIs(of: playlist, fields: nil, into: &uris)
        }
        index[playlist.id] = CachedPlaylist(snapshotID: playlist.snapshotID ?? "", uris: uris)
        saveIndex()
        return uris
    }

    private func collectURIs(of playlist: Playlist, fields: String?, into uris: inout Set<String>) async throws {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let fields { query.append(URLQueryItem(name: "fields", value: fields)) }
        var next: URL? = api.url("playlists/\(playlist.id)/items", query: query)
        var pages = 0
        while let url = next, pages < 200 {
            try Task.checkCancellation()
            let page = try await api.get(url, as: SpotifyPage<SpotifyPlaylistEntry>.self)
            uris.formUnion(page.items.compactMap(\.uri))
            next = page.next.flatMap(URL.init(string:))
            pages += 1
        }
    }

    /// Keeps the cache valid after our own edit, so the next check needs no request.
    private func recordChange(in playlist: Playlist, response: Data, edit: (inout Set<String>) -> Void) -> Playlist {
        var updated = playlist
        guard let snapshot = try? JSONDecoder().decode(SpotifySnapshot.self, from: response).snapshot_id else {
            index[playlist.id] = nil
            return updated
        }
        updated.snapshotID = snapshot
        if var cached = index[playlist.id], cached.snapshotID == playlist.snapshotID {
            edit(&cached.uris)
            cached.snapshotID = snapshot
            index[playlist.id] = cached
        } else {
            index[playlist.id] = nil
        }
        saveIndex()
        return updated
    }

    private static var indexURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "com.ghalielouahdani.MusicNotch/spotify-playlists.json")
    }

    private static func loadIndex() -> [Playlist.ID: CachedPlaylist] {
        guard let data = try? Data(contentsOf: indexURL) else { return [:] }
        return (try? JSONDecoder().decode([Playlist.ID: CachedPlaylist].self, from: data)) ?? [:]
    }

    private func saveIndex() {
        let url = Self.indexURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(index).write(to: url, options: .atomic)
    }
}
