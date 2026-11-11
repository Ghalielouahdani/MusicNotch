import AppKit
import Observation

/// Tracks what's playing in Spotify or Music.
///
/// Both players post a distributed notification on every change, so the state is
/// refreshed on demand instead of polled. Between refreshes the position is
/// extrapolated from the last sample.
@MainActor
@Observable
final class NowPlayingController {
    private(set) var playback: PlaybackState?
    private(set) var artwork: NSImage?
    private(set) var accentColor: NSColor?
    /// Players the user hasn't allowed MusicNotch to control.
    private(set) var deniedSources: Set<MusicSource> = []

    var track: Track? { playback?.track }
    var isPlaying: Bool { playback?.isPlaying == true }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var lastActiveSource: MusicSource?
    @ObservationIgnored private var artworkTrackID: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var volumeSender: Task<Void, Never>?
    @ObservationIgnored private var pendingVolume: (Int, MusicSource)?
    @ObservationIgnored private var volumeChangedAt: Date?
    @ObservationIgnored private var volumeBeforeMute: Double?

    func start() {
        let distributed = DistributedNotificationCenter.default()
        let playerNotifications: [(String, MusicSource)] = [
            ("com.spotify.client.PlaybackStateChanged", .spotify),
            ("com.apple.Music.playerInfo", .appleMusic),
        ]
        for (name, source) in playerNotifications {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastActiveSource = source
                    self?.scheduleRefresh(after: .milliseconds(60))
                }
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let playerIDs = Set(MusicSource.allCases.map(\.bundleID))
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, playerIDs.contains(id) else { return }
                MainActor.assumeIsolated { self?.scheduleRefresh(after: .milliseconds(500)) }
            })
        }
        scheduleRefresh()
    }

    /// While the notch is open, re-sample every few seconds to correct drift
    /// (seeking inside the player app doesn't always post a notification).
    func setLiveUpdates(_ enabled: Bool) {
        liveTask?.cancel()
        liveTask = nil
        guard enabled else { return }
        scheduleRefresh()
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.scheduleRefresh()
            }
        }
    }

    func scheduleRefresh(after delay: Duration = .zero) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Controls

    func togglePlayPause() {
        guard var state = playback else { return }
        // Respond on the same frame: flip locally, then let the player confirm.
        let now = Date()
        state.position = state.position(at: now)
        state.sampledAt = now
        state.isPlaying.toggle()
        playback = state
        send(PlayerScripts.command(.playPause, for: state.track.source))
    }

    func toggleShuffle() {
        guard var state = playback, let isShuffling = state.isShuffling else { return }
        state.isShuffling = !isShuffling
        playback = state
        send(PlayerScripts.setShuffle(!isShuffling, for: state.track.source))
    }

    /// Sets the player's volume (0...1). Safe to call on every drag tick: while one
    /// Apple Event is in flight, only the latest level is kept and sent next.
    func setVolume(_ level: Double) {
        guard var state = playback else { return }
        let clamped = min(1, max(0, level))
        state.volume = clamped
        playback = state
        volumeChangedAt = Date()
        pendingVolume = (Int((clamped * 100).rounded()), state.track.source)

        guard volumeSender == nil else { return }
        volumeSender = Task {
            while let (level, source) = pendingVolume {
                pendingVolume = nil
                _ = try? await AppleScriptRunner.shared.run(PlayerScripts.setVolume(level, for: source))
            }
            volumeSender = nil
        }
    }

    /// Mutes, or restores the level from before muting.
    func toggleMute() {
        guard let volume = playback?.volume else { return }
        if volume > 0 {
            volumeBeforeMute = volume
            setVolume(0)
        } else {
            setVolume(volumeBeforeMute ?? 0.5)
        }
    }

    func skip(forward: Bool) {
        guard let source = playback?.track.source else { return }
        send(PlayerScripts.command(forward ? .next : .previous, for: source))
    }

    func seek(to seconds: TimeInterval) {
        guard var state = playback else { return }
        state.position = seconds
        state.sampledAt = Date()
        playback = state
        send(PlayerScripts.seek(to: seconds, for: state.track.source), cache: false)
    }

    private func send(_ script: String, cache: Bool = true) {
        Task {
            _ = try? await AppleScriptRunner.shared.run(script, cache: cache)
            scheduleRefresh(after: .milliseconds(300))
        }
    }

    // MARK: Refresh

    private enum Sample {
        case playing(PlaybackState)
        case idle
        case denied
    }

    private func refresh() async {
        var states: [PlaybackState] = []
        var denied: Set<MusicSource> = []
        for source in MusicSource.allCases {
            switch await sample(source) {
            case .playing(let state): states.append(state)
            case .denied: denied.insert(source)
            case .idle: break
            }
        }
        guard !Task.isCancelled else { return }
        if deniedSources != denied { deniedSources = denied }

        // Prefer whatever is audibly playing, then whatever the user touched last.
        let playing = states.filter(\.isPlaying)
        let current = playback?.track.source
        let chosen = playing.first { $0.track.source == lastActiveSource }
            ?? playing.first
            ?? states.first { $0.track.source == current }
            ?? states.first { $0.track.source == lastActiveSource }
            ?? states.first
        apply(chosen)
    }

    private func sample(_ source: MusicSource) async -> Sample {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty else {
            return .idle
        }
        do {
            let value = try await AppleScriptRunner.shared.run(PlayerScripts.state(for: source))
            let state = PlayerScripts.parseState(value, source: source, at: Date())
            Log.media.info("\(source.rawValue, privacy: .public): \(state.map { $0.isPlaying ? "playing" : "paused" } ?? "idle", privacy: .public) \(state?.track.title ?? "", privacy: .private)")
            return state.map(Sample.playing) ?? .idle
        } catch let error as ScriptError where error.isPermissionDenied {
            Log.media.error("\(source.rawValue, privacy: .public): automation permission denied")
            return .denied
        } catch {
            Log.media.error("\(source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .idle
        }
    }

    private func apply(_ state: PlaybackState?) {
        var state = state
        // A sample taken mid-drag can trail the level just set; keep ours for a moment.
        if let changedAt = volumeChangedAt, Date().timeIntervalSince(changedAt) < 1.5,
           state?.track.source == playback?.track.source {
            state?.volume = playback?.volume
        }
        playback = state
        loadArtwork(for: state?.track)
    }

    private func loadArtwork(for track: Track?) {
        let key = track.map { "\($0.source.rawValue):\($0.id):\($0.title)" }
        guard key != artworkTrackID else { return }
        artworkTrackID = key
        guard let track else {
            artwork = nil
            accentColor = nil
            return
        }
        Task {
            let image: NSImage? = switch track.source {
            case .spotify:
                await ImageLoader.shared.image(for: track.artworkURL)
            case .appleMusic:
                (try? await AppleScriptRunner.shared.run(PlayerScripts.musicArtwork))?.data.flatMap(NSImage.init(data:))
            }
            // The song may have changed while the artwork was loading.
            guard artworkTrackID == key else { return }
            artwork = image
            accentColor = image?.accentColor
        }
    }

    // MARK: Previews

    func showPreview(_ state: PlaybackState, artwork: NSImage?) {
        playback = state
        self.artwork = artwork
        accentColor = artwork?.accentColor
    }
}
