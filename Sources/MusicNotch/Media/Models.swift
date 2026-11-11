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

    /// Extrapolates the position so the progress bar moves without polling the player.
    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let elapsed = position + date.timeIntervalSince(sampledAt)
        return track.duration > 0 ? min(elapsed, track.duration) : elapsed
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
