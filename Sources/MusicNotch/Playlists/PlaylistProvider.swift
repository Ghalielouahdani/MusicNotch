import Foundation

/// A music service whose playlists the current song can be added to.
protocol PlaylistProvider: AnyObject {
    /// Playlists the user can edit, with the favorites collection first.
    func playlists() async throws -> [Playlist]

    /// IDs of the playlists that already hold `track`. Calls `progress` as results
    /// arrive so checkmarks can appear before a slow check finishes.
    func playlistsContaining(
        _ track: Track,
        among playlists: [Playlist],
        progress: (Set<Playlist.ID>) -> Void
    ) async throws -> Set<Playlist.ID>

    /// Returns the playlist with any updated version marker.
    func add(_ track: Track, to playlist: Playlist) async throws -> Playlist
    func remove(_ track: Track, from playlist: Playlist) async throws -> Playlist
}
