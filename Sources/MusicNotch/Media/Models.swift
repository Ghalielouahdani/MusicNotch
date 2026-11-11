import Foundation

/// A music app MusicNotch can read from and write playlists to.
nonisolated enum MusicSource: String, Sendable, CaseIterable {
    case spotify
    case appleMusic

    var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .appleMusic: "com.apple.Music"
        }
    }

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Music"
        }
    }

    var favoritesName: String {
        switch self {
        case .spotify: "Liked Songs"
        case .appleMusic: "Favorite Songs"
        }
    }
}

nonisolated struct Track: Equatable, Sendable {
    /// Spotify URI (`spotify:track:…`) or the Music persistent ID.
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var artworkURL: URL?
    var source: MusicSource

    /// Spotify can't put local files or ads in a playlist.
    var canAddToPlaylists: Bool {
        switch source {
        case .spotify: id.hasPrefix("spotify:track:") || id.hasPrefix("spotify:episode:")
        case .appleMusic: !id.isEmpty
        }
    }
}

nonisolated struct PlaybackState: Equatable, Sendable {
    var track: Track
    var isPlaying: Bool
    /// Position in seconds when the state was sampled.
    var position: TimeInterval
    var sampledAt: Date
    /// Nil when the player didn't say.
    var isShuffling: Bool? = nil
    /// The player's own volume, 0...1. Nil when the player didn't say.
    var volume: Double? = nil

    /// Extrapolates the position so the progress bar moves without polling the player.
    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let elapsed = position + date.timeIntervalSince(sampledAt)
        return track.duration > 0 ? min(elapsed, track.duration) : elapsed
    }
}

extension Collection {
    /// The element at `index`, or nil when it's out of bounds.
    nonisolated subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A song inside a playlist, in playlist order.
nonisolated struct PlaylistTrack: Identifiable, Equatable, Sendable {
    /// Position in the playlist. The same song can appear twice, so it can't be the ID.
    var position: Int
    /// Spotify URI or Music persistent ID.
    var trackID: String
    var title: String
    var artist: String
    var duration: TimeInterval

    var id: Int { position }

    func matches(_ track: Track?) -> Bool {
        guard let track else { return false }
        if trackID == track.id { return true }
        // Spotify relinks some songs to a different URI; fall back to title and artist.
        return title == track.title && artist.hasPrefix(track.artist)
    }
}

nonisolated struct Playlist: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case favorites, regular }

    var id: String
    var name: String
    var kind: Kind
    var imageURL: URL?
    /// Spotify's version marker, used to know when a cached track list is stale.
    var snapshotID: String?
}
