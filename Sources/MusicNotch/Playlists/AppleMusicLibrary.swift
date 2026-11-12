import Foundation

/// Music.app playlists through AppleScript. Works with no setup.
@MainActor
final class AppleMusicLibrary: PlaylistProvider {
    static let favoritesID = "music:favorites"

    func playlists() async throws -> [Playlist] {
        let value = try await AppleScriptRunner.shared.run(MusicScripts.playlists)
        let ids = value[0].list.compactMap(\.string)
        let names = value[1].list.compactMap(\.string)
        let playlists = zip(ids, names).map { Playlist(id: $0, name: $1, kind: .regular) }
        return [Playlist(id: Self.favoritesID, name: MusicSource.appleMusic.favoritesName, kind: .favorites)] + playlists
    }

    func playlistsContaining(
        _ track: Track,
        among playlists: [Playlist],
        progress: (Set<Playlist.ID>) -> Void
    ) async throws -> Set<Playlist.ID> {
        let value = try await AppleScriptRunner.shared.run(MusicScripts.membership)
        // The song may have changed since the request started.
        guard value[0].string == track.title, value[1].string == track.artist else { return [] }
        var found = Set(value[3].list.compactMap(\.string))
        if value[2].bool == true { found.insert(Self.favoritesID) }
        return found
    }

    func add(_ track: Track, to playlist: Playlist) async throws -> Playlist {
        let trackID = try Self.validated(track.id)
        let script = playlist.kind == .favorites
            ? MusicScripts.setFavorite(true, trackID: trackID)
            : MusicScripts.add(trackID: trackID, playlistID: try Self.validated(playlist.id))
        try await AppleScriptRunner.shared.run(script, cache: false)
        return playlist
    }

    func remove(_ track: Track, from playlist: Playlist) async throws -> Playlist {
        let trackID = try Self.validated(track.id)
        let script = playlist.kind == .favorites
            ? MusicScripts.setFavorite(false, trackID: trackID)
            : MusicScripts.remove(trackID: trackID, playlistID: try Self.validated(playlist.id))
        try await AppleScriptRunner.shared.run(script, cache: false)
        return playlist
    }

    /// Favorites are a filter on the library, not a playlist Music can start.
    func canPlay(_ playlist: Playlist) -> Bool { playlist.kind == .regular }

    func play(_ playlist: Playlist) async throws {
        try await AppleScriptRunner.shared.run(MusicScripts.play(playlistID: try Self.validated(playlist.id)), cache: false)
    }

    func play(_ track: PlaylistTrack, in playlist: Playlist) async throws {
        let script = MusicScripts.play(trackID: try Self.validated(track.trackID), playlistID: try Self.validated(playlist.id))
        try await AppleScriptRunner.shared.run(script, cache: false)
    }

    func tracks(in playlist: Playlist, progress: ([PlaylistTrack]) -> Void) async throws -> [PlaylistTrack] {
        guard playlist.kind == .regular else { return [] }
        let value = try await AppleScriptRunner.shared.run(MusicScripts.tracks(playlistID: try Self.validated(playlist.id)), cache: false)
        let ids = value[0].list, names = value[1].list, artists = value[2].list, durations = value[3].list
        return ids.indices.compactMap { index in
            guard let id = ids[index].string, let name = names[safe: index]?.string else { return nil }
            return PlaylistTrack(
                position: index,
                trackID: id,
                title: name,
                artist: artists[safe: index]?.string ?? "",
                duration: durations[safe: index]?.double ?? 0
            )
        }
    }

    /// Persistent IDs are hex. Anything else must not reach a script.
    private static func validated(_ id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit) else {
            throw ScriptError(number: -1, message: "This song can't be added from here.")
        }
        return id
    }
}

/// AppleScript sources for Music's library. IDs passed in must already be validated hex.
enum MusicScripts {
    private static let editablePlaylists = "every user playlist whose smart is false and special kind is none"

    static let playlists = """
        tell application id "com.apple.Music"
            with timeout of 10 seconds
                return {persistent ID of (\(editablePlaylists)), name of (\(editablePlaylists))}
            end timeout
        end tell
        """

    /// Matches on title + artist: a song streamed from Apple Music and its library
    /// copy don't share a persistent ID.
    static let membership = """
        tell application id "com.apple.Music"
            with timeout of 15 seconds
                set theTrack to current track
                set trackName to name of theTrack
                set trackArtist to artist of theTrack
                set isFavorite to false
                try
                    set isFavorite to favorited of theTrack
                end try
                set foundIDs to {}
                repeat with thePlaylist in (\(editablePlaylists))
                    try
                        if (count of (tracks of thePlaylist whose name is trackName and artist is trackArtist)) > 0 then
                            set end of foundIDs to (persistent ID of thePlaylist)
                        end if
                    end try
                end repeat
                return {trackName, trackArtist, isFavorite, foundIDs}
            end timeout
        end tell
        """

    static func add(trackID: String, playlistID: String) -> String {
        """
        tell application id "com.apple.Music"
            with timeout of 15 seconds
                \(currentTrack(trackID))
                set thePlaylist to (first user playlist whose persistent ID is "\(playlistID)")
                try
                    duplicate theTrack to thePlaylist
                on error errMsg number errNum
                    -- A song streamed from Apple Music has to be in the library before it can go in a playlist.
                    try
                        duplicate theTrack to library playlist 1
                    end try
                    set trackName to name of theTrack
                    set trackArtist to artist of theTrack
                    set libraryCopies to (tracks of library playlist 1 whose name is trackName and artist is trackArtist)
                    if libraryCopies is {} then error errMsg number errNum
                    duplicate (item 1 of libraryCopies) to thePlaylist
                end try
            end timeout
        end tell
        """
    }

    static func remove(trackID: String, playlistID: String) -> String {
        """
        tell application id "com.apple.Music"
            with timeout of 15 seconds
                \(currentTrack(trackID))
                set thePlaylist to (first user playlist whose persistent ID is "\(playlistID)")
                set trackName to name of theTrack
                set trackArtist to artist of theTrack
                delete (every track of thePlaylist whose name is trackName and artist is trackArtist)
            end timeout
        end tell
        """
    }

    static func setFavorite(_ favorite: Bool, trackID: String) -> String {
        """
        tell application id "com.apple.Music"
            with timeout of 10 seconds
                \(currentTrack(trackID))
                set favorited of theTrack to \(favorite)
            end timeout
        end tell
        """
    }

    static func play(playlistID: String) -> String {
        """
        tell application id "com.apple.Music"
            play (first user playlist whose persistent ID is "\(playlistID)")
        end tell
        """
    }

    /// Playing the playlist's own entry keeps playback going through that playlist.
    static func play(trackID: String, playlistID: String) -> String {
        """
        tell application id "com.apple.Music"
            set thePlaylist to (first user playlist whose persistent ID is "\(playlistID)")
            play (first track of thePlaylist whose persistent ID is "\(trackID)")
        end tell
        """
    }

    /// Four bulk reads instead of one per song, so long playlists stay fast.
    static func tracks(playlistID: String) -> String {
        """
        tell application id "com.apple.Music"
            with timeout of 20 seconds
                set thePlaylist to (first user playlist whose persistent ID is "\(playlistID)")
                return {persistent ID of every track of thePlaylist, name of every track of thePlaylist, artist of every track of thePlaylist, duration of every track of thePlaylist}
            end timeout
        end tell
        """
    }

    /// Binds `theTrack` to the current track, refusing to act if the song changed meanwhile.
    private static func currentTrack(_ trackID: String) -> String {
        """
        set theTrack to current track
                if persistent ID of theTrack is not "\(trackID)" then error "The song changed. Try again." number 9001
        """
    }

    /// Every script, for `--check-scripts`.
    static var all: [(String, String)] {
        [
            ("music.playlists", playlists),
            ("music.membership", membership),
            ("music.add", add(trackID: "ABCDEF0123456789", playlistID: "0123456789ABCDEF")),
            ("music.remove", remove(trackID: "ABCDEF0123456789", playlistID: "0123456789ABCDEF")),
            ("music.favorite", setFavorite(true, trackID: "ABCDEF0123456789")),
            ("spotify.state", PlayerScripts.state(for: .spotify)),
            ("music.state", PlayerScripts.state(for: .appleMusic)),
            ("music.artwork", PlayerScripts.musicArtwork),
            ("spotify.playpause", PlayerScripts.command(.playPause, for: .spotify)),
            ("music.next", PlayerScripts.command(.next, for: .appleMusic)),
            ("spotify.seek", PlayerScripts.seek(to: 42.5, for: .spotify)),
            ("spotify.shuffle", PlayerScripts.setShuffle(true, for: .spotify)),
            ("music.shuffle", PlayerScripts.setShuffle(false, for: .appleMusic)),
            ("spotify.repeat", PlayerScripts.setRepeat(.all, for: .spotify)),
            ("music.repeat", PlayerScripts.setRepeat(.one, for: .appleMusic)),
            ("spotify.volume", PlayerScripts.setVolume(40, for: .spotify)),
            ("spotify.playPlaylist", (try? PlayerScripts.spotifyPlay("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")) ?? "FAIL"),
            ("spotify.playInContext", (try? PlayerScripts.spotifyPlay(
                "spotify:track:4uLU6hMCjMI75M1A2tKUQC", inContext: "spotify:user:someone_1:collection")) ?? "FAIL"),
            ("music.playPlaylist", play(playlistID: "0123456789ABCDEF")),
            ("music.playTrack", play(trackID: "ABCDEF0123456789", playlistID: "0123456789ABCDEF")),
            ("music.tracks", tracks(playlistID: "0123456789ABCDEF")),
            ("music.volume", PlayerScripts.setVolume(75, for: .appleMusic)),
        ]
    }
}
