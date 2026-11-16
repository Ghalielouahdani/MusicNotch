import Foundation

/// Rebuilds the user's Spotify activity from the dates the Web API exposes:
/// `added_at` / `added_by` on playlist items, and `added_at` on Liked Songs.
///
/// Each playlist's events are cached on disk and re-read only when its snapshot ID changes.
@MainActor
final class SpotifyContributions {
    private let api: SpotifyAPI
    private var cache: [String: CachedPlaylist]

    private struct CachedPlaylist: Codable {
        var snapshotID: String
        var events: [ContributionEvent]
    }

    init(auth: SpotifyAuth) {
        api = SpotifyAPI(auth: auth)
        cache = Self.loadCache()
    }

    func events(progress: (String) -> Void) async throws -> [ContributionEvent] {
        let me = try await api.get(api.url("me"), as: SpotifyUser.self).id
        var events: [ContributionEvent] = []

        progress("Reading Liked Songs…")
        events += try await likedSongs()

        let playlists = try await editablePlaylists(of: me)
        for (index, playlist) in playlists.enumerated() {
            try Task.checkCancellation()
            progress("Reading \(playlist.name) (\(index + 1) of \(playlists.count))…")
            if let snapshot = playlist.snapshot_id, let cached = cache[playlist.id], cached.snapshotID == snapshot {
                events += cached.events
                continue
            }
            let found = try await events(in: playlist, me: me)
            if let snapshot = playlist.snapshot_id {
                cache[playlist.id] = CachedPlaylist(snapshotID: snapshot, events: found)
            }
            events += found
        }
        saveCache()
        return events
    }

    func forgetAccount() {
        cache = [:]
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    // MARK: Private

    private func editablePlaylists(of me: String) async throws -> [SpotifyPlaylist] {
        var result: [SpotifyPlaylist] = []
        var next: URL? = api.url("me/playlists", query: [URLQueryItem(name: "limit", value: "50")])
        var pages = 0
        while let url = next, pages < 20 {
            let page = try await api.get(url, as: SpotifyPage<SpotifyPlaylist>.self)
            result += page.items.filter { $0.owner?.id == me || $0.collaborative == true }
            next = page.next.flatMap(URL.init(string:))
            pages += 1
        }
        return result
    }

    private func likedSongs() async throws -> [ContributionEvent] {
        let entries = try await allEntries(from: api.url("me/tracks", query: [URLQueryItem(name: "limit", value: "50")]))
        return entries.compactMap { entry in
            guard let date = Self.date(entry.added_at) else { return nil }
            return ContributionEvent(date: date, kind: .liked, trackName: entry.ref?.name, artist: entry.artistNames)
        }
    }

    private func events(in playlist: SpotifyPlaylist, me: String) async throws -> [ContributionEvent] {
        let limit = URLQueryItem(name: "limit", value: "50")
        let fields = "next,items(added_at,added_by(id),item(name,artists(name)),track(name,artists(name)))"
        let entries: [SpotifyPlaylistEntry]
        do {
            entries = try await allEntries(from: api.url(
                "playlists/\(playlist.id)/items", query: [limit, URLQueryItem(name: "fields", value: fields)]
            ))
        } catch SpotifyError.http(400, _) {
            // Same fallback as SpotifyLibrary, in case `fields` rejects the new key.
            entries = try await allEntries(from: api.url("playlists/\(playlist.id)/items", query: [limit]))
        }

        var events: [ContributionEvent] = []
        var earliest: Date?
        for entry in entries {
            guard let date = Self.date(entry.added_at) else { continue }
            earliest = min(earliest ?? date, date)
            // Collaborative playlists: only count the songs this user added.
            guard entry.added_by?.id == nil || entry.added_by?.id == me else { continue }
            events.append(ContributionEvent(
                date: date, kind: .addedToPlaylist,
                trackName: entry.ref?.name, artist: entry.artistNames, playlistName: playlist.name
            ))
        }
        if let earliest, playlist.owner?.id == me {
            events.append(ContributionEvent(date: earliest, kind: .createdPlaylist, playlistName: playlist.name))
        }
        return events
    }

    private func allEntries(from url: URL) async throws -> [SpotifyPlaylistEntry] {
        var entries: [SpotifyPlaylistEntry] = []
        var next: URL? = url
        var pages = 0
        while let current = next, pages < 400 {
            try Task.checkCancellation()
            let page = try await api.get(current, as: SpotifyPage<SpotifyPlaylistEntry>.self)
            entries += page.items
            next = page.next.flatMap(URL.init(string:))
            pages += 1
        }
        return entries
    }

    /// Songs added before about 2014 come back with no date or with 1970.
    private static func date(_ string: String?) -> Date? {
        guard let string, let date = try? Date(string, strategy: .iso8601) else { return nil }
        return date.timeIntervalSince1970 > 1_000_000_000 ? date : nil
    }

    private static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "com.ghalielouahdani.MusicNotch/spotify-contributions.json")
    }

    private static func loadCache() -> [String: CachedPlaylist] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedPlaylist].self, from: data)) ?? [:]
    }

    private func saveCache() {
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
}
