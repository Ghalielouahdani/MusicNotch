import AppKit
import SwiftUI

/// A borderless window over the whole screen, under the notch so the notch keeps working.
private final class FullScreenWindow: NSWindow {
    var onClose: () -> Void = {}
    var onPlayPause: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc.
    override func cancelOperation(_ sender: Any?) { onClose() }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onPlayPause()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            onClose()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Shows the playing song's cover over the whole screen, on the colors of its artwork.
@MainActor
final class FullScreenWindowController {
    private let nowPlaying: NowPlayingController
    private var window: FullScreenWindow?

    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}

    var isOpen: Bool { window != nil }

    init(nowPlaying: NowPlayingController) {
        self.nowPlaying = nowPlaying
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard window == nil else { return }
        // The screen the pointer is on.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }

        let window = FullScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .mainMenu + 2
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.hasShadow = false
        window.onClose = { [weak self] in self?.close() }
        window.onPlayPause = { [weak self] in self?.nowPlaying.togglePlayPause() }
        window.contentView = NSHostingView(rootView: FullScreenPlayerView(nowPlaying: nowPlaying) { [weak self] in
            self?.close()
        })
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        onOpen()
    }

    func close() {
        guard let window else { return }
        self.window = nil
        NSCursor.setHiddenUntilMouseMoves(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.contentView = nil
            }
        }
        onClose()
    }
}
