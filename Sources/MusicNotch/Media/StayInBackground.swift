import AppKit

/// Some players bring themselves to the front when told to play through
/// AppleScript (Spotify does). This runs such a command and, if the player
/// wasn't already the frontmost app, hides it again so you stay where you were.
enum StayInBackground {
    static func run(bundleID: String, _ command: () async throws -> Void) async throws {
        let player = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let wasFrontmost = player?.isActive ?? false
        try await command()
        guard let player, !wasFrontmost else { return }

        // Activation lands a moment after the command returns.
        for _ in 0..<15 where !player.isActive {
            try? await Task.sleep(for: .milliseconds(60))
        }
        // Hiding hands focus back to the app that had it.
        if player.isActive { player.hide() }
    }
}
