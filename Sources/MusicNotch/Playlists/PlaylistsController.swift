import AppKit
import Observation

/// Playlists for whichever app is playing, and which of them hold the current song.
@Observable
final class PlaylistsController {
    enum Phase: Equatable {
        case noSong
        case loading
        case ready
        case needsSpotifyLogin
        case permissionDenied(MusicSource)
        case failed(String)
    }

    struct Notice: Equatable {
        enum Kind { case added, removed, playing, error }
        var kind: Kind
        var text: String
        var id = UUID()
    }

    private(set) var phase: Phase = .noSong
    private(set) var playlists: [Playlist] = []
    private(set) var containing: Set<Playlist.ID> = []
    private(set) var inFlight: Set<Playlist.ID> = []
    private(set) var notice: Notice?
    /// The playlist the user started from the notch, while the song still belongs to it.
    private(set) var playingPlaylistID: Playlist.ID?

    let spotifyAuth: SpotifyAuth
    private let spotify: SpotifyLibrary
    private let music: AppleMusicLibrary

    @ObservationIgnored private var loadedSource: MusicSource?
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var checkedTrackID: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(spotifyAuth: SpotifyAuth) {
        self.spotifyAuth = spotifyAuth
        spotify = SpotifyLibrary(auth: spotifyAuth)
        music = AppleMusicLibrary()
    }

    /// Call when the notch opens or the song changes while it's open.
    func refresh(for track: Track?, force: Bool = false) {
        guard let track else {
            loadTask?.cancel()
            phase = .noSong
            return
        }
        if track.source == .spotify, spotifyAuth.status != .connected {
            loadTask?.cancel()
            phase = .needsSpotifyLogin
            playlists = []
            loadedSource = nil
            return
        }

        let sourceChanged = loadedSource != track.source
        let stale = loadedAt.map { Date().timeIntervalSince($0) > 60 } ?? true
        let needsList = force || sourceChanged || stale || playlists.isEmpty
        let needsCheck = needsList || checkedTrackID != track.id
        guard needsCheck else { return }

        if sourceChanged {
            playlists = []
            containing = []
            playingPlaylistID = nil
        }
        if checkedTrackID != track.id { containing = [] }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.load(track: track, reloadList: needsList)
        }
    }

    func toggle(_ playlist: Playlist, for track: Track) {
        guard !inFlight.contains(playlist.id), track.canAddToPlaylists else { return }
        let provider = provider(for: track.source)
        let removing = containing.contains(playlist.id)
        inFlight.insert(playlist.id)

        Task {
            defer { inFlight.remove(playlist.id) }
            do {
                let updated = removing
                    ? try await provider.remove(track, from: playlist)
                    : try await provider.add(track, to: playlist)
                if let index = playlists.firstIndex(where: { $0.id == updated.id }) {
                    playlists[index] = updated
                }
                if removing {
                    containing.remove(playlist.id)
                    show(Notice(kind: .removed, text: "Removed from \(playlist.name)"))
                } else {
                    containing.insert(playlist.id)
                    // Confirm on the same frame the checkmark lands.
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                    show(Notice(kind: .added, text: "Added to \(playlist.name)"))
                }
            } catch {
                Log.playlists.error("\(removing ? "remove" : "add", privacy: .public) failed: \(String(describing: error), privacy: .public)")
                handle(error, source: track.source)
                show(Notice(kind: .error, text: Self.message(for: error)))
            }
        }
    }

    func canPlay(_ playlist: Playlist, source: MusicSource) -> Bool {
        provider(for: source).canPlay(playlist)
    }

    func play(_ playlist: Playlist, source: MusicSource) {
        let provider = provider(for: source)
        let previous = playingPlaylistID
        playingPlaylistID = playlist.id
        Task {
            do {
                try await provider.play(playlist)
                show(Notice(kind: .playing, text: "Playing \(playlist.name)"))
            } catch {
                Log.playlists.error("play failed: \(String(describing: error), privacy: .public)")
                if playingPlaylistID == playlist.id { playingPlaylistID = previous }
                handle(error, source: source)
                show(Notice(kind: .error, text: Self.message(for: error)))
            }
        }
    }

    func disconnectSpotify() {
        spotifyAuth.disconnect()
        spotify.forgetAccount()
        if loadedSource == .spotify {
            loadTask?.cancel()
            playlists = []
            containing = []
            loadedSource = nil
            checkedTrackID = nil
        }
    }

    // MARK: Private

    private func provider(for source: MusicSource) -> any PlaylistProvider {
        switch source {
        case .spotify: spotify
        case .appleMusic: music
        }
    }

    private func load(track: Track, reloadList: Bool) async {
        let provider = provider(for: track.source)
        do {
            if reloadList {
                if playlists.isEmpty { phase = .loading }
                let fresh = try await provider.playlists()
                guard !Task.isCancelled else { return }
                playlists = fresh
                loadedSource = track.source
                loadedAt = Date()
            }
            phase = .ready
            guard track.canAddToPlaylists else { return }

            let found = try await provider.playlistsContaining(track, among: playlists) { [weak self] partial in
                guard !Task.isCancelled else { return }
                self?.containing = partial
            }
            guard !Task.isCancelled else { return }
            containing = found
            checkedTrackID = track.id
            // Playback moved on to a song outside the playlist we started.
            if let playing = playingPlaylistID, !found.contains(playing) { playingPlaylistID = nil }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            Log.playlists.error("load \(track.source.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            handle(error, source: track.source)
            // Keep showing a stale list rather than replacing it with an error.
            if playlists.isEmpty, phase == .loading || phase == .ready {
                phase = .failed(Self.message(for: error))
            }
        }
    }

    private func handle(_ error: Error, source: MusicSource) {
        if let error = error as? ScriptError, error.isPermissionDenied {
            phase = .permissionDenied(source)
        } else if case SpotifyError.notConnected = error {
            phase = .needsSpotifyLogin
        }
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? ScriptError {
            if error.isPermissionDenied { return "MusicNotch isn't allowed to control Music." }
            if error.number == 9001 { return error.message }
            if error.number == -1728 || error.number == -10000 {
                return "Music can't add this song. Add it to your library first."
            }
            return error.message
        }
        if case SpotifyError.http(403, _) = error {
            return "Spotify won't let you edit this playlist."
        }
        return error.localizedDescription
    }

    // MARK: Previews

    func showPreview(
        playlists: [Playlist],
        containing: Set<Playlist.ID>,
        inFlight: Set<Playlist.ID> = [],
        notice: Notice? = nil,
        playingPlaylistID: Playlist.ID? = nil
    ) {
        phase = .ready
        self.playingPlaylistID = playingPlaylistID
        self.playlists = playlists
        self.containing = containing
        self.inFlight = inFlight
        self.notice = notice
    }
}
