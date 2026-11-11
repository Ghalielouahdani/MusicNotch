import AppKit
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let spotifyAuth = SpotifyAuth()
    private let nowPlaying = NowPlayingController()
    private lazy var playlists = PlaylistsController(spotifyAuth: spotifyAuth)

    private var notch: NotchWindowController?
    private var notchIsOpen = false
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        nowPlaying.start()

        guard let screen = NotchGeometry.preferredScreen else { return }
        let model = NotchViewModel(geometry: NotchGeometry(screen: screen), nowPlaying: nowPlaying, settings: settings)
        let root = NotchRootView(model: model, nowPlaying: nowPlaying, playlists: playlists, actions: notchActions)
        let controller = NotchWindowController(
            model: model,
            rootView: root,
            pinnedOpen: CommandLine.arguments.contains("--pin-open")
        )
        controller.onOpen = { [weak self] in self?.notchOpened() }
        controller.onClose = { [weak self] in self?.notchClosed() }
        notch = controller
        if CommandLine.arguments.contains("--pin-open") { notchOpened() }

        updateStatusItem()
        observeChanges()

        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            showSettings()
        }
    }

    // MARK: Notch

    private var notchActions: NotchActions {
        NotchActions(
            openSettings: { [weak self] in self?.showSettings() },
            connectSpotify: { [weak self] in self?.connectSpotify() },
            openAutomationSettings: {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                NSWorkspace.shared.open(url)
            },
            retryPlaylists: { [weak self] in
                guard let self else { return }
                playlists.refresh(for: nowPlaying.track, force: true)
            },
            openPlayer: { [weak self] in
                guard let source = self?.nowPlaying.track?.source,
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        )
    }

    private func notchOpened() {
        notchIsOpen = true
        nowPlaying.setLiveUpdates(true)
        playlists.refresh(for: nowPlaying.track)
    }

    private func notchClosed() {
        notchIsOpen = false
        nowPlaying.setLiveUpdates(false)
    }

    private func connectSpotify() {
        if spotifyAuth.clientID.trimmingCharacters(in: .whitespaces).isEmpty {
            showSettings()
        } else {
            Task { await spotifyAuth.connect() }
        }
    }

    /// Re-checks playlists when the song or the Spotify login changes, and keeps
    /// the menu bar icon in sync with settings.
    private func observeChanges() {
        withObservationTracking {
            _ = nowPlaying.track?.id
            _ = spotifyAuth.status
            _ = settings.showMenuBarIcon
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if notchIsOpen { playlists.refresh(for: nowPlaying.track) }
                updateStatusItem()
                observeChanges()
            }
        }
    }

    // MARK: Settings

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, auth: spotifyAuth) { [weak self] in
                guard let self else { return }
                playlists.disconnectSpotify()
                playlists.refresh(for: nowPlaying.track, force: true)
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "MusicNotch"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func updateStatusItem() {
        guard settings.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MusicNotch")
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MusicNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }
}
