import AppKit
import SwiftUI

struct OpenNotchView: View {
    let model: NotchViewModel
    let nowPlaying: NowPlayingController
    let playlists: PlaylistsController
    let actions: NotchActions

    var body: some View {
        VStack(spacing: 0) {
            NotchHeader(source: nowPlaying.track?.source, notice: playlists.notice, openSettings: actions.openSettings)
                .frame(height: model.notchSize.height)
                .padding(.horizontal, 30)

            HStack(alignment: .top, spacing: 22) {
                NowPlayingSection(nowPlaying: nowPlaying, openPlayer: actions.openPlayer)
                    .frame(width: 314)
                PlaylistSection(playlists: playlists, track: nowPlaying.track, isPlaying: nowPlaying.isPlaying, actions: actions)
            }
            .padding(.top, 10)
            .padding(.horizontal, 30)
            .padding(.bottom, 18)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The band beside the hardware notch: the source on the left, the playlist
/// title (or the latest confirmation) and settings on the right.
private struct NotchHeader: View {
    let source: MusicSource?
    let notice: PlaylistsController.Notice?
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let source {
                HStack(spacing: 6) {
                    AppIcon(bundleID: source.bundleID).frame(width: 14, height: 14)
                    Text(source.displayName)
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                if let notice {
                    NoticeLabel(notice: notice)
                        .id(notice.id)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                } else {
                    Text("Add to Playlist")
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 1), value: notice)
            IconButton(symbol: "gearshape.fill", size: 11, help: "MusicNotch Settings", action: openSettings)
                .padding(.leading, 8)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.5))
    }
}

private struct NoticeLabel: View {
    let notice: PlaylistsController.Notice

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(notice.text).lineLimit(1)
        }
        .foregroundStyle(notice.kind == .error ? Color(red: 1, green: 0.62, blue: 0.4) : .white.opacity(0.85))
        .frame(maxWidth: 190, alignment: .trailing)
    }

    private var symbol: String {
        switch notice.kind {
        case .added: "checkmark"
        case .removed: "minus"
        case .playing: "play.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

// MARK: Now playing

struct NowPlayingSection: View {
    let nowPlaying: NowPlayingController
    let openPlayer: () -> Void

    var body: some View {
        let track = nowPlaying.track
        HStack(alignment: .top, spacing: 14) {
            Button(action: openPlayer) {
                ArtworkView(image: nowPlaying.artwork, cornerRadius: 12)
                    .frame(width: 96, height: 96)
                    // Like Music: the cover rests a little smaller while paused.
                    .scaleEffect(nowPlaying.isPlaying || track == nil ? 1 : 0.93)
                    .shadow(color: Color(nsColor: nowPlaying.accentColor ?? .black).opacity(nowPlaying.isPlaying ? 0.35 : 0),
                            radius: 16, y: 4)
                    .animation(.spring(response: 0.45, dampingFraction: 0.82), value: nowPlaying.isPlaying)
            }
            .buttonStyle(PressableStyle(scale: 0.96))
            .help(track.map { "Open \($0.source.displayName)" } ?? "")
            .disabled(track == nil)

            VStack(alignment: .leading, spacing: 0) {
                Text(track?.title ?? "Nothing playing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle(for: track))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .padding(.top, 1)

                Spacer(minLength: 4)

                if let playback = nowPlaying.playback {
                    PlaybackScrubber(playback: playback, onSeek: nowPlaying.seek(to:))
                }
                PlaybackControls(nowPlaying: nowPlaying)
                    .padding(.top, 4)
            }
            .frame(height: 96)
        }
    }

    private func subtitle(for track: Track?) -> String {
        guard let track else {
            return nowPlaying.deniedSources.isEmpty
                ? "Play something in Spotify or Music"
                : "Allow MusicNotch in Privacy & Security › Automation"
        }
        return track.artist.isEmpty ? track.album : track.artist
    }
}

private struct PlaybackControls: View {
    let nowPlaying: NowPlayingController

    static let sideSlotWidth: CGFloat = 26

    @State private var showsVolume = false
    @State private var isHoveringSpeaker = false
    @State private var isHoveringSlider = false
    @State private var isDraggingVolume = false
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        let enabled = nowPlaying.track != nil
        let volume = nowPlaying.playback?.volume
        HStack(spacing: 0) {
            ShuffleButton(
                isOn: nowPlaying.playback?.isShuffling == true,
                accent: nowPlaying.track?.source.accent ?? .white,
                action: { nowPlaying.toggleShuffle() }
            )
            .frame(width: Self.sideSlotWidth)
            .disabled(nowPlaying.playback?.isShuffling == nil)

            ZStack {
                HStack(spacing: 10) {
                    IconButton(symbol: "backward.fill", size: 14, help: "Previous") { nowPlaying.skip(forward: false) }
                    IconButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 20,
                               help: nowPlaying.isPlaying ? "Pause" : "Play") { nowPlaying.togglePlayPause() }
                    IconButton(symbol: "forward.fill", size: 14, help: "Next") { nowPlaying.skip(forward: true) }
                }
                .opacity(showsVolume ? 0 : 1)
                .scaleEffect(showsVolume ? 0.94 : 1)
                .allowsHitTesting(!showsVolume)

                if showsVolume, let volume {
                    VolumeSlider(volume: volume, isDragging: $isDraggingVolume) { nowPlaying.setVolume($0) }
                        .padding(.leading, 10)
                        .padding(.trailing, 4)
                        .onHover { isHoveringSlider = $0 }
                        // Grows out of the speaker and folds back into it.
                        .transition(.scale(scale: 0.2, anchor: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)

            VolumeButton(volume: volume) { nowPlaying.toggleMute() }
                .frame(width: Self.sideSlotWidth)
                .onHover { isHoveringSpeaker = $0 }
                .disabled(volume == nil)
        }
        .foregroundStyle(.white.opacity(enabled ? 0.92 : 0.3))
        .disabled(!enabled)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: showsVolume)
        .onChange(of: isHoveringSpeaker || isHoveringSlider || isDraggingVolume) { _, engaged in
            updateVolumeVisibility(engaged: engaged)
        }
    }

    /// Opens at once; closes after a short pause so moving from the speaker onto
    /// the slider (or slipping off it) doesn't snap it shut.
    private func updateVolumeVisibility(engaged: Bool) {
        collapseTask?.cancel()
        if engaged {
            showsVolume = true
        } else {
            collapseTask = Task {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                showsVolume = false
            }
        }
    }
}

/// The speaker: its waves fill with the volume. Click to mute or unmute.
private struct VolumeButton: View {
    let volume: Double?
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let level = volume ?? 0
        let muted = level < 0.005
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: level)
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(isHovering && isEnabled ? 0.85 : 0.5))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(muted ? "Unmute" : "Mute")
        .accessibilityLabel(muted ? "Unmute" : "Mute")
        .accessibilityValue("Volume \(Int((level * 100).rounded())) percent")
    }
}

/// Same feel as the progress bar: grab anywhere, it follows the pointer 1:1.
private struct VolumeSlider: View {
    let volume: Double
    @Binding var isDragging: Bool
    let onChange: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { proxy in
            let value = dragValue ?? volume
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(.white.opacity(0.92))
                    .frame(width: proxy.size.width * value)
            }
            .frame(height: isDragging ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let level = min(1, max(0, gesture.location.x / max(proxy.size.width, 1)))
                        dragValue = level
                        onChange(level)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragValue = nil
                    }
            )
        }
        .frame(height: 26)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: isDragging)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { volume }, set: { onChange($0) }), in: 0...1) {
                Text("Volume")
            }
        }
    }
}

/// Shuffle, lit in the player's color when on. A dot underneath says "on"
/// without relying on color alone.
private struct ShuffleButton: View {
    let isOn: Bool
    let accent: Color
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "shuffle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? accent : .white.opacity(isHovering && isEnabled ? 0.85 : 0.5))
                .frame(width: 26, height: 26)
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(accent)
                        .frame(width: 3, height: 3)
                        .scaleEffect(isOn ? 1 : 0.2)
                        .opacity(isOn ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 1), value: isOn)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(isOn ? "Turn Shuffle Off" : "Turn Shuffle On")
        .accessibilityLabel("Shuffle")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A progress bar you can grab: it follows the pointer 1:1 and seeks on release.
private struct PlaybackScrubber: View {
    let playback: PlaybackState
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?
    @State private var isHovering = false

    var body: some View {
        let duration = max(playback.track.duration, 1)
        let active = isHovering || dragFraction != nil
        // The bar moves under a point per second, so a few frames a second look continuous.
        TimelineView(.animation(minimumInterval: 0.25, paused: !playback.isPlaying || dragFraction != nil)) { context in
            let fraction = dragFraction ?? min(1, max(0, playback.position(at: context.date) / duration))
            VStack(spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(.white.opacity(active ? 1 : 0.85))
                            .frame(width: max(active ? 6 : 4, proxy.size.width * fraction))
                    }
                    .frame(height: active ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(1, max(0, value.location.x / proxy.size.width))
                            }
                            .onEnded { _ in
                                if let dragFraction { onSeek(dragFraction * duration) }
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 10)

                HStack {
                    Text(Self.format(fraction * duration))
                    Spacer()
                    Text("-" + Self.format(duration - fraction * duration))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
            }
        }
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 1), value: active)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: Playlists

struct PlaylistSection: View {
    let playlists: PlaylistsController
    let track: Track?
    let isPlaying: Bool
    let actions: NotchActions

    var body: some View {
        Group {
            switch playlists.phase {
            case .noSong:
                Placeholder(symbol: "music.note.list", text: "Play a song to add it to a playlist.")
            case .loading:
                SkeletonRows()
            case .needsSpotifyLogin:
                Placeholder(symbol: "person.crop.circle.badge.plus",
                            text: "Connect Spotify to add songs to your playlists.",
                            button: "Connect Spotify", action: actions.connectSpotify)
            case .permissionDenied(let source):
                Placeholder(symbol: "lock.fill",
                            text: "Allow MusicNotch to control \(source.displayName).",
                            button: "Open Privacy Settings", action: actions.openAutomationSettings)
            case .failed(let message):
                Placeholder(symbol: "exclamationmark.triangle", text: message,
                            button: "Try Again", action: actions.retryPlaylists)
            case .ready:
                PlaylistList(playlists: playlists, track: track, isPlaying: isPlaying)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private nonisolated struct ScrollEdges: Equatable {
    var top = false
    var bottom = false
}

private struct PlaylistList: View {
    let playlists: PlaylistsController
    let track: Track?
    let isPlaying: Bool

    @State private var edges = ScrollEdges()
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let rows = VStack(spacing: 2) {
            ForEach(playlists.playlists) { playlist in
                let source = track?.source ?? .spotify
                PlaylistRow(
                    playlist: playlist,
                    source: source,
                    isAdded: playlists.containing.contains(playlist.id),
                    isBusy: playlists.inFlight.contains(playlist.id),
                    isEnabled: track?.canAddToPlaylists == true,
                    canPlay: track != nil && playlists.canPlay(playlist, source: source),
                    isPlayingFrom: playlists.playingPlaylistID == playlist.id,
                    isPlaying: isPlaying,
                    toggle: { if let track { playlists.toggle(playlist, for: track) } },
                    play: { playlists.play(playlist, source: source) }
                )
            }
        }

        if isSnapshot {
            rows.frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
                .mask(fadeMask(ScrollEdges(top: false, bottom: playlists.playlists.count > 3)))
        } else {
            ScrollView(.vertical) { rows }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                    ScrollEdges(
                        top: geometry.contentOffset.y > 1,
                        bottom: geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
                    )
                } action: { _, new in
                    edges = new
                }
                // Fade only the edge that has more content, instead of a hard divider.
                .mask(fadeMask(edges))
                .animation(.easeOut(duration: 0.15), value: edges)
        }
    }

    private func fadeMask(_ edges: ScrollEdges) -> some View {
        LinearGradient(stops: [
            .init(color: edges.top ? .clear : .black, location: 0),
            .init(color: .black, location: 0.16),
            .init(color: .black, location: 0.82),
            .init(color: edges.bottom ? .clear : .black, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// One playlist: click the row to add or remove the song; the play button
/// beside the (+) starts the playlist.
private struct PlaylistRow: View {
    let playlist: Playlist
    let source: MusicSource
    let isAdded: Bool
    let isBusy: Bool
    let isEnabled: Bool
    let canPlay: Bool
    let isPlayingFrom: Bool
    let isPlaying: Bool
    let toggle: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    /// Room kept free in the row for the play button, which sits on top of it.
    private static let playSlot: CGFloat = 22
    private static let rowPadding: CGFloat = 7
    private static let spacing: CGFloat = 9
    private static let statusWidth: CGFloat = 18

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Self.spacing) {
                PlaylistCover(playlist: playlist, source: source)
                    .frame(width: 24, height: 24)
                Text(playlist.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isEnabled || canPlay ? 0.92 : 0.4))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if canPlay { Color.clear.frame(width: Self.playSlot, height: 1) }
                status.frame(width: Self.statusWidth, height: 18)
            }
            .padding(.horizontal, Self.rowPadding)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(isHighlighted: isHovering && (isEnabled || canPlay)))
        .disabled(!isEnabled)
        // A separate button above the row, so it isn't swallowed by the row's own click.
        .overlay(alignment: .trailing) {
            if canPlay {
                PlayPlaylistButton(
                    name: playlist.name,
                    accent: source.accent,
                    isRevealed: isHovering,
                    isPlayingFrom: isPlayingFrom,
                    isPlaying: isPlaying,
                    action: play
                )
                .frame(width: Self.playSlot)
                .padding(.trailing, Self.rowPadding + Self.statusWidth + Self.spacing)
            }
        }
        .onHover { isHovering = $0 }
        .help(isAdded ? "Remove from \(playlist.name)" : "Add to \(playlist.name)")
        .accessibilityLabel(isAdded ? "Remove from \(playlist.name)" : "Add to \(playlist.name)")
        .accessibilityValue(isAdded ? "Added" : "")
    }

    private var status: some View {
        ZStack {
            if isBusy {
                Spinner()
                    .transition(.opacity)
            } else if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(source.accent)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            } else if isHovering && isEnabled {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55))
                    .transition(.opacity)
            }
        }
        // The checkmark is a completion moment, so it earns a little bounce.
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: isAdded)
        .animation(.easeOut(duration: 0.12), value: isBusy)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// The row lights up on hover and brightens the instant it's pressed.
private struct RowButtonStyle: ButtonStyle {
    let isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.15 : (isHighlighted ? 0.09 : 0)))
            )
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
    }
}

/// Play, shown on hover. On the playlist that's playing it stays visible as a
/// waveform moving with the music.
private struct PlayPlaylistButton: View {
    let name: String
    let accent: Color
    let isRevealed: Bool
    let isPlayingFrom: Bool
    let isPlaying: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = isRevealed || isPlayingFrom
        Button(action: action) {
            ZStack {
                if isPlayingFrom {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying && !reduceMotion)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(isHovering ? 1 : 0.7))
                        .transition(.opacity)
                }
            }
            .frame(width: 22, height: 22)
            .background(Circle().fill(.white.opacity(isHovering ? 0.14 : 0)))
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: visible)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPlayingFrom)
        .help("Play \(name)")
        .accessibilityLabel("Play \(name)")
    }
}

private struct PlaylistCover: View {
    let playlist: Playlist
    let source: MusicSource

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Group {
            if playlist.kind == .favorites {
                ZStack {
                    source.favoritesGradient
                    Image(systemName: source == .spotify ? "heart.fill" : "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            } else {
                RemoteImage(url: playlist.imageURL) {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note.list")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .clipShape(shape)
    }
}

private struct Placeholder: View {
    let symbol: String
    let text: String
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let button {
                Button(button, action: action)
                    .buttonStyle(CapsuleButtonStyle())
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SkeletonRows: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).frame(width: 24, height: 24)
                    RoundedRectangle(cornerRadius: 3, style: .continuous).frame(width: CGFloat([110, 80, 130, 95][index]), height: 9)
                    Spacer()
                }
                .padding(.horizontal, 7)
                .frame(height: 30)
            }
        }
        .foregroundStyle(.white.opacity(0.07))
        .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.45]) { content, opacity in
            content.opacity(opacity)
        } animation: { _ in
            .easeInOut(duration: 0.9)
        }
    }
}
