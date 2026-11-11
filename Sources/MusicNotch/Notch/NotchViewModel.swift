import AppKit
import Observation

/// Where the hardware notch is on a screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize

    init(screenFrame: CGRect, notchSize: CGSize) {
        self.screenFrame = screenFrame
        self.notchSize = notchSize
    }

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            // No notch (external display): draw one the height of the menu bar.
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 190, height: menuBar > 0 ? menuBar : 24)
        }
    }

    /// The built-in display with the notch, else the main display.
    static var preferredScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

@Observable
final class NotchViewModel {
    enum State { case closed, peek, open }

    static let openWidth: CGFloat = 640
    static let contentHeight: CGFloat = 138

    var state: State = .closed
    var geometry: NotchGeometry

    private let nowPlaying: NowPlayingController
    private let settings: AppSettings

    init(geometry: NotchGeometry, nowPlaying: NowPlayingController, settings: AppSettings) {
        self.geometry = geometry
        self.nowPlaying = nowPlaying
        self.settings = settings
    }

    var notchSize: CGSize { geometry.notchSize }

    var openSize: CGSize {
        CGSize(width: Self.openWidth, height: notchSize.height + Self.contentHeight)
    }

    /// Artwork and a visualizer beside the notch while music plays.
    var showsActivity: Bool {
        settings.showSongBesideNotch && nowPlaying.isPlaying
    }

    var activityEarWidth: CGFloat { notchSize.height + 8 }

    var closedSize: CGSize {
        guard showsActivity else { return notchSize }
        return CGSize(width: notchSize.width + 2 * activityEarWidth, height: notchSize.height)
    }

    var size: CGSize {
        switch state {
        case .closed: closedSize
        // A small swell that says "something lives here" before it opens.
        case .peek: CGSize(width: closedSize.width + 20, height: closedSize.height + 6)
        case .open: openSize
        }
    }

    var topRadius: CGFloat { state == .open ? 14 : 6 }
    var bottomRadius: CGFloat {
        switch state {
        case .closed: 11
        case .peek: 14
        case .open: 28
        }
    }
}
