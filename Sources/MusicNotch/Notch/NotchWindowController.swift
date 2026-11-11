import AppKit
import SwiftUI

/// A borderless panel that floats over the menu bar and never takes focus.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click land on a button even though the panel is never key.
/// (Not generic: a generic NSHostingView subclass crashes the Swift 6.3 optimizer.)
final class NotchHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Positions the panel over the notch and turns pointer movement into
/// closed → peek → open → closed.
final class NotchWindowController {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private let model: NotchViewModel
    private let panel = NotchPanel()
    private let pinnedOpen: Bool
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var trackingTimer: Timer?
    private var dwellTask: Task<Void, Never>?
    private var outsideSince: Date?

    /// Space around the open notch for its shadow.
    private static let shadowInset: CGFloat = 40
    /// How long the pointer rests on the notch before it opens.
    private static let dwell: Duration = .milliseconds(110)
    /// Forgives a pointer that slips out of the open notch for a moment.
    private static let closeGrace: TimeInterval = 0.22

    init(model: NotchViewModel, rootView: some View, pinnedOpen: Bool = false) {
        self.model = model
        self.pinnedOpen = pinnedOpen

        let hosting = NotchHostingView(rootView: AnyView(rootView))
        hosting.sizingOptions = []
        panel.contentView = hosting

        reposition()
        panel.orderFrontRegardless()
        installMonitors()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        })

        if pinnedOpen { open() }
    }

    func close() {
        guard model.state != .closed, !pinnedOpen else { return }
        dwellTask?.cancel()
        stopTracking()
        panel.ignoresMouseEvents = true
        setState(.closed)
        onClose?()
    }

    // MARK: Layout

    private func reposition() {
        guard let screen = NotchGeometry.preferredScreen else { return }
        let geometry = NotchGeometry(screen: screen)
        if model.geometry != geometry { model.geometry = geometry }

        let size = CGSize(
            width: NotchViewModel.openWidth + Self.shadowInset * 2,
            height: model.openSize.height + Self.shadowInset
        )
        let frame = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }

    /// The area that wakes the notch: the notch itself and a little below it.
    private var hotZone: CGRect {
        let frame = model.geometry.screenFrame
        let width = model.closedSize.width + 16
        let height = model.notchSize.height + 8
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height + 1)
    }

    private var openZone: CGRect {
        let frame = model.geometry.screenFrame
        let width = model.openSize.width + 16
        let height = model.openSize.height + 14
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height + 1)
    }

    // MARK: Pointer

    private func installMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func pointerMoved() {
        guard model.state != .open else { return }
        let inside = hotZone.contains(NSEvent.mouseLocation)
        if inside, model.state == .closed {
            setState(.peek)
            dwellTask?.cancel()
            dwellTask = Task { [weak self] in
                try? await Task.sleep(for: Self.dwell)
                guard !Task.isCancelled, let self, self.hotZone.contains(NSEvent.mouseLocation) else { return }
                self.open()
            }
        } else if !inside, model.state == .peek {
            dwellTask?.cancel()
            setState(.closed)
        }
    }

    private func open() {
        guard model.state != .open else { return }
        panel.ignoresMouseEvents = false
        setState(.open)
        startTracking()
        onOpen?()
    }

    /// While open, sample the pointer directly: once it's over our own panel,
    /// mouse-moved events may not reach the global monitor.
    private func startTracking() {
        outsideSince = nil
        trackingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackOpenPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func trackOpenPointer() {
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        if openZone.contains(NSEvent.mouseLocation) || dragging || pinnedOpen {
            outsideSince = nil
            return
        }
        let since = outsideSince ?? Date()
        outsideSince = since
        if Date().timeIntervalSince(since) >= Self.closeGrace { close() }
    }

    private func setState(_ state: NotchViewModel.State) {
        guard model.state != state else { return }
        let animation: Animation = if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            .easeOut(duration: 0.18)
        } else {
            switch state {
            // Grows out of the notch with a whisper of overshoot, settles back without one.
            case .open: .spring(response: 0.42, dampingFraction: 0.86)
            case .peek: .spring(response: 0.3, dampingFraction: 0.9)
            case .closed: .spring(response: 0.36, dampingFraction: 1)
            }
        }
        withAnimation(animation) { model.state = state }
    }
}
