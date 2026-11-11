import SwiftUI

/// What the notch can ask the app to do.
struct NotchActions {
    var openSettings: () -> Void = {}
    var connectSpotify: () -> Void = {}
    var openAutomationSettings: () -> Void = {}
    var retryPlaylists: () -> Void = {}
    var openPlayer: () -> Void = {}
}

/// The black notch outline: flared top corners that melt into the screen edge,
/// rounded bottom corners.
nonisolated struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = max(0, min(bottomRadius, rect.height - top, (rect.width - 2 * top) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct NotchRootView: View {
    let model: NotchViewModel
    let nowPlaying: NowPlayingController
    let playlists: PlaylistsController
    let actions: NotchActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius)
        let size = model.size

        shape
            .fill(.black)
            .frame(width: size.width, height: size.height)
            // Content keeps its final size and is revealed by the growing shape,
            // so nothing squishes on the way in or out.
            .overlay(alignment: .top) { content }
            .clipShape(shape)
            .shadow(color: .black.opacity(model.state == .open ? 0.55 : 0), radius: 18, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(response: 0.4, dampingFraction: 1), value: model.showsActivity)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .top) {
            if model.state == .open {
                OpenNotchView(model: model, nowPlaying: nowPlaying, playlists: playlists, actions: actions)
                    .frame(width: model.openSize.width, height: model.openSize.height)
                    .transition(.materialize(reduceMotion: reduceMotion))
            } else if model.showsActivity {
                ClosedActivityView(model: model, nowPlaying: nowPlaying)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
    }
}

/// The song beside the closed notch: artwork on the left, a visualizer on the right.
struct ClosedActivityView: View {
    let model: NotchViewModel
    let nowPlaying: NowPlayingController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let height = model.notchSize.height
        HStack(spacing: 0) {
            ArtworkView(image: nowPlaying.artwork, cornerRadius: 5)
                .frame(width: height - 12, height: height - 12)
                .frame(width: model.activityEarWidth)
            Spacer(minLength: 0)
            EqualizerBars(
                color: nowPlaying.accentColor ?? .white,
                isAnimating: nowPlaying.isPlaying && !reduceMotion
            )
            .frame(width: 16, height: height * 0.36)
            .frame(width: model.activityEarWidth)
        }
        .frame(width: model.closedSize.width, height: height)
    }
}

// MARK: Transition

/// Content arrives like a material settling into place: fade, blur and scale
/// together, anchored to the notch it grows out of — and leaves the same way.
private struct Materialize: ViewModifier {
    var progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.92 + 0.08 * progress, anchor: .top)
            .blur(radius: (1 - progress) * 10)
    }
}

extension AnyTransition {
    static func materialize(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let base = AnyTransition.modifier(active: Materialize(progress: 0), identity: Materialize(progress: 1))
        return .asymmetric(
            insertion: base.animation(.spring(response: 0.38, dampingFraction: 1).delay(0.05)),
            removal: base.animation(.spring(response: 0.2, dampingFraction: 1))
        )
    }
}
