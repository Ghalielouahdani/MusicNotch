import AppKit
import SwiftUI

/// Renders the notch with sample data to PNGs: `MusicNotch --snapshot <folder>`.
/// Used to review the design without touching the real notch.
enum SnapshotRenderer {
    static func render(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let track = Track(
            id: "spotify:track:sample", title: "Midnight City", artist: "M83",
            album: "Hurry Up, We're Dreaming", duration: 243, artworkURL: nil, source: .spotify
        )
        let playlistsSample = [
            Playlist(id: SpotifyLibrary.likedSongsID, name: "Liked Songs", kind: .favorites),
            Playlist(id: "a", name: "Late night drives", kind: .regular),
            Playlist(id: "b", name: "Focus — deep work", kind: .regular),
            Playlist(id: "c", name: "Summer '26", kind: .regular),
            Playlist(id: "d", name: "Running", kind: .regular),
        ]

        for (name, state, configure) in variants {
            let settings = AppSettings()
            let nowPlaying = NowPlayingController()
            nowPlaying.showPreview(
                PlaybackState(track: track, isPlaying: true, position: 81, sampledAt: .now, isShuffling: true),
                artwork: sampleArtwork()
            )
            let playlists = PlaylistsController(spotifyAuth: SpotifyAuth())
            playlists.showPreview(playlists: playlistsSample, containing: [SpotifyLibrary.likedSongsID, "a"])
            configure(playlists)

            let geometry = NotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                notchSize: CGSize(width: 185, height: 32)
            )
            let model = NotchViewModel(geometry: geometry, nowPlaying: nowPlaying, settings: settings)
            model.state = state

            let view = NotchRootView(model: model, nowPlaying: nowPlaying, playlists: playlists, actions: NotchActions())
                .frame(width: 720, height: 230)
                .background(
                    LinearGradient(colors: [Color(white: 0.92), Color(white: 0.78)], startPoint: .top, endPoint: .bottom)
                )
                .environment(\.isSnapshot, true)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: folder.appending(path: "\(name).png"))
        }
    }

    private static let variants: [(String, NotchViewModel.State, (PlaylistsController) -> Void)] = [
        ("open", .open, { _ in }),
        ("open-adding", .open, { controller in
            controller.showPreview(
                playlists: controller.playlists,
                containing: [SpotifyLibrary.likedSongsID, "a"],
                inFlight: ["b"],
                notice: .init(kind: .added, text: "Added to Late night drives")
            )
        }),
        ("closed-playing", .closed, { _ in }),
        ("peek", .peek, { _ in }),
    ]

    private static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [
                NSColor(red: 0.95, green: 0.35, blue: 0.55, alpha: 1),
                NSColor(red: 0.35, green: 0.2, blue: 0.75, alpha: 1),
                NSColor(red: 0.08, green: 0.1, blue: 0.3, alpha: 1),
            ])?.draw(in: rect, angle: -60)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 170, y: 170, width: 60, height: 60)).fill()
            return true
        }
    }
}
