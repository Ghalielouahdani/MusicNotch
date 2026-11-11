import Foundation

/// Music.app playlists through AppleScript. Works with no setup.
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

    /// Persistent IDs are hex. Anything else must not reach a script.
    private static func validated(_ id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit) else {
            throw ScriptError(number: -1, message: "This song can't be added from here.")
        }
        return id
    }
}

/// AppleScript sources for Music's library. IDs passed in must already be validated hex.
nonisolated enum MusicScripts {
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
        ]
    }
}
