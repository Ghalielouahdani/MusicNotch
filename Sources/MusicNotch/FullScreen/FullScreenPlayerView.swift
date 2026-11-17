import AppKit
import SwiftUI

/// The cover in the middle of the screen, on a slowly drifting gradient of its own colors.
/// Controls appear while the pointer moves and fade away, with the pointer, once it rests.
struct FullScreenPlayerView: View {
    let nowPlaying: NowPlayingController
    let close: () -> Void

    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let idleDelay: Duration = .seconds(2.5)

    var body: some View {
        let track = nowPlaying.track
        GeometryReader { proxy in
            let coverSide = min(proxy.size.height * 0.5, proxy.size.width * 0.42)
            ZStack {
                AlbumColorsBackground(colors: colors, animated: !reduceMotion)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ArtworkView(image: nowPlaying.artwork, cornerRadius: coverSide * 0.04)
                        .frame(width: coverSide, height: coverSide)
                        .scaleEffect(nowPlaying.isPlaying || track == nil ? 1 : 0.94)
                        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: nowPlaying.isPlaying)

                    VStack(spacing: 6) {
                        Text(track?.title ?? "Nothing playing")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                        if let subtitle = subtitle(for: track) {
                            Text(subtitle)
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                    .frame(maxWidth: coverSide * 1.6)
                    .padding(.top, 36)

                    // Always laid out, so the cover doesn't shift when controls come and go.
                    VStack(spacing: 10) {
                        if let playback = nowPlaying.playback {
                            PlaybackScrubber(playback: playback, onSeek: nowPlaying.seek(to:))
                        }
                        PlaybackControls(nowPlaying: nowPlaying)
                    }
                    .frame(width: 340)
                    .scaleEffect(1.25)
                    .padding(.top, 40)
                    .opacity(showsControls ? 1 : 0)
                    .allowsHitTesting(showsControls)

                    Spacer(minLength: 0)
                }
                .padding(.bottom, 20)
            }
            .overlay(alignment: .topLeading) {
                IconButton(symbol: "xmark", size: 14, help: "Exit Full Screen (Esc)", action: close)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(28)
                    .opacity(showsControls ? 1 : 0)
                    .allowsHitTesting(showsControls)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.3), value: showsControls)
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onAppear(perform: revealControls)
        .onDisappear { hideTask?.cancel() }
    }

    private var colors: [Color] {
        let palette = nowPlaying.palette
        guard !palette.isEmpty else {
            return [Color(white: 0.16), Color(white: 0.1), Color(white: 0.22), Color(white: 0.08)]
        }
        return palette.map { Color(nsColor: $0) }
    }

    private func subtitle(for track: Track?) -> String? {
        guard let track else { return nil }
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private func revealControls() {
        showsControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled else { return }
            showsControls = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// A 4×4 mesh of the album's colors that flows like liquid: inner points swirl on
/// out-of-step loops, edge points slide along their edge, and each spot slowly blends
/// toward a neighboring color, so nothing repeats in an obvious way.
private struct AlbumColorsBackground: View {
    let colors: [Color]
    let animated: Bool

    var body: some View {
        ZStack {
            mesh
                .id(colors)
                .transition(.opacity)
            // Keeps white text readable on light covers.
            LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.32)], startPoint: .top, endPoint: .bottom)
        }
        // A new song's colors melt in rather than cut.
        .animation(.easeInOut(duration: 1.4), value: colors)
        .ignoresSafeArea()
    }

    private var mesh: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let t = animated ? context.date.timeIntervalSinceReferenceDate : 0
            MeshGradient(
                width: Self.side, height: Self.side,
                points: Self.points(at: t),
                colors: colors(at: t),
                smoothsColors: true
            )
        }
    }

    private static let side = 4

    /// Sixteen spots from four colors, spread so no color sits next to itself, each
    /// drifting toward the next color and back.
    private func colors(at t: TimeInterval) -> [Color] {
        let palette = (0..<4).map { colors[$0 % colors.count] }
        return (0..<(Self.side * Self.side)).map { index in
            let row = index / Self.side, column = index % Self.side
            let base = (row + column * 2) % 4
            let blend = (sin(t * 2 * .pi / (9 + Double(index % 5) * 1.7) + Double(index) * 1.9) + 1) / 2
            return palette[base].mix(with: palette[(base + 1) % 4], by: blend * 0.7)
        }
    }

    private static func points(at t: TimeInterval) -> [SIMD2<Float>] {
        let last = side - 1
        let step = 1 / Double(last)
        // Two waves at unrelated speeds make a swirl instead of a back-and-forth.
        func swirl(_ seed: Double, _ amount: Double) -> Double {
            amount * (0.65 * sin(t * 2 * .pi / (7 + seed.truncatingRemainder(dividingBy: 5)) + seed)
                    + 0.35 * sin(t * 2 * .pi / (3.1 + seed.truncatingRemainder(dividingBy: 2.3)) + seed * 2.7))
        }
        var points: [SIMD2<Float>] = []
        for row in 0...last {
            for column in 0...last {
                let seed = Double(row * side + column) * 1.37 + 0.5
                var x = Double(column) * step, y = Double(row) * step
                let onVerticalEdge = column == 0 || column == last
                let onHorizontalEdge = row == 0 || row == last
                // Corners stay pinned so the screen edges are always covered.
                if !onVerticalEdge { x += swirl(seed, step * 0.42) }
                if !onHorizontalEdge { y += swirl(seed + 3.3, step * 0.42) }
                points.append([Float(x), Float(y)])
            }
        }
        return points
    }
}
