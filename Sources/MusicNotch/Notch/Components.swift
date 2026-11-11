import AppKit
import SwiftUI

extension MusicSource {
    var accent: Color {
        switch self {
        case .spotify: Color(red: 0.12, green: 0.84, blue: 0.38)
        case .appleMusic: Color(red: 0.98, green: 0.18, blue: 0.28)
        }
    }

    var favoritesGradient: LinearGradient {
        switch self {
        case .spotify:
            LinearGradient(colors: [Color(red: 0.27, green: 0.04, blue: 0.96), Color(red: 0.77, green: 0.94, blue: 0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .appleMusic:
            LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.47), Color(red: 0.98, green: 0.14, blue: 0.25)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when rendering a still image, where scroll views and AppKit controls don't draw.
    /// (Spelled out because the `@Entry` macro plugin ships only with Xcode.)
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

/// Shrinks on press, immediately: feedback belongs to the press, not the release.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.75 : 0.95)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// An SF Symbol button with a soft circular hover highlight.
struct IconButton: View {
    let symbol: String
    let size: CGFloat
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 16, height: size + 12)
                .background(Circle().fill(.white.opacity(isHovering && isEnabled ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The shape sets the size; the glyph and the image are overlays so they can't stretch it.
        shape.fill(.white.opacity(0.08))
            .overlay {
                GeometryReader { proxy in
                    Image(systemName: "music.note")
                        .font(.system(size: proxy.size.height * 0.3, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                }
            }
            .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.3), value: image.map(ObjectIdentifier.init))
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .animation(.easeOut(duration: 0.2), value: image.map(ObjectIdentifier.init))
        .task(id: url) {
            image = ImageLoader.shared.cached(url)
            if image == nil { image = await ImageLoader.shared.image(for: url) }
        }
    }
}

struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let icon = Self.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        }
    }

    private static var cache: [String: NSImage] = [:]

    /// The app's icon flattened to a small bitmap. Workspace icons draw lazily through
    /// IconServices, which is slower and misbehaves in rendered snapshots.
    private static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(bitmap)
        cache[bundleID] = image
        return image
    }
}

/// Four bars that dance while music plays, tinted with the cover's color.
///
/// Core Animation runs the loop in the render server, so the bars cost almost no
/// CPU, unlike a SwiftUI timeline redrawing 30 times a second for as long as music plays.
struct EqualizerBars: View {
    let color: NSColor
    let isAnimating: Bool

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // Still images can't contain AppKit views; draw the resting pose instead.
            HStack(spacing: 2) {
                ForEach(Array(EqualizerLayerView.restingLevels.enumerated()), id: \.offset) { _, level in
                    GeometryReader { proxy in
                        Capsule().fill(Color(nsColor: color))
                            .frame(height: proxy.size.height * level)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: 2.5)
                }
            }
        } else {
            EqualizerRepresentable(color: color, isAnimating: isAnimating)
        }
    }
}

private struct EqualizerRepresentable: NSViewRepresentable {
    let color: NSColor
    let isAnimating: Bool

    func makeNSView(context: Context) -> EqualizerLayerView { EqualizerLayerView() }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.update(color: color, isAnimating: isAnimating)
    }
}

final class EqualizerLayerView: NSView {
    static let restingLevels: [CGFloat] = [0.45, 0.8, 0.6, 0.35]
    private static let barWidth: CGFloat = 2.5
    private static let spacing: CGFloat = 2
    /// Each bar loops through its own heights at its own pace, so they never sync up.
    private static let patterns: [(levels: [CGFloat], duration: CFTimeInterval)] = [
        ([0.35, 0.9, 0.5, 1.0, 0.3, 0.7, 0.35], 1.9),
        ([0.8, 0.4, 1.0, 0.55, 0.9, 0.3, 0.8], 1.55),
        ([0.5, 1.0, 0.35, 0.75, 0.45, 0.95, 0.5], 1.75),
        ([0.3, 0.65, 0.9, 0.4, 0.8, 0.5, 0.3], 2.1),
    ]

    private var bars: [CALayer] = []
    private var isAnimating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in Self.restingLevels {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let totalWidth = CGFloat(bars.count) * Self.barWidth + CGFloat(bars.count - 1) * Self.spacing
        var x = (bounds.width - totalWidth) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height * Self.restingLevels[index])
            bar.position = CGPoint(x: x + Self.barWidth / 2, y: bounds.midY)
            x += Self.barWidth + Self.spacing
        }
        CATransaction.commit()
        if isAnimating { startAnimations() }
    }

    func update(color: NSColor, isAnimating: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()

        guard isAnimating != self.isAnimating else { return }
        self.isAnimating = isAnimating
        if isAnimating { startAnimations() } else { bars.forEach { $0.removeAllAnimations() } }
    }

    private func startAnimations() {
        let height = bounds.height
        guard height > 0 else { return }
        for (bar, pattern) in zip(bars, Self.patterns) {
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
            animation.values = pattern.levels.map { max(3, height * $0) }
            animation.duration = pattern.duration
            animation.calculationMode = .cubic
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            bar.add(animation, forKey: "dance")
        }
    }
}

/// A small spinner drawn in SwiftUI, so it also shows up in rendered snapshots.
struct Spinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 1)
            .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
