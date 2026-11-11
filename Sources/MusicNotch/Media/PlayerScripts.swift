import Foundation

/// AppleScript sources for reading and controlling the players.
///
/// Every script checks `is running` first: a bare `tell application` would launch the app.
nonisolated enum PlayerScripts {
    enum Command { case playPause, next, previous }

    static func state(for source: MusicSource) -> String {
        switch source {
        case .spotify:
            """
            if application id "com.spotify.client" is not running then return {"stopped"}
            tell application id "com.spotify.client"
                with timeout of 3 seconds
                    set playerState to player state as string
                    if playerState is "stopped" then return {"stopped"}
                    set theTrack to current track
                    return {playerState, id of theTrack, name of theTrack, artist of theTrack, album of theTrack, duration of theTrack, player position, artwork url of theTrack, shuffling}
                end timeout
            end tell
            """
        case .appleMusic:
            """
            if application id "com.apple.Music" is not running then return {"stopped"}
            tell application id "com.apple.Music"
                with timeout of 3 seconds
                    set playerState to player state as string
                    if playerState is "stopped" then return {"stopped"}
                    set theTrack to current track
                    set trackID to ""
                    try
                        set trackID to persistent ID of theTrack
                    end try
                    set trackDuration to 0
                    try
                        set trackDuration to duration of theTrack
                    end try
                    -- Same layout as Spotify's; Music has no artwork URL, so that slot is empty.
                    return {playerState, trackID, name of theTrack, artist of theTrack, album of theTrack, trackDuration, player position, "", shuffle enabled}
                end timeout
            end tell
            """
        }
    }

    static let musicArtwork = """
        if application id "com.apple.Music" is not running then return missing value
        tell application id "com.apple.Music"
            with timeout of 3 seconds
                try
                    return raw data of artwork 1 of current track
                on error
                    return missing value
                end try
            end timeout
        end tell
        """

    static func command(_ command: Command, for source: MusicSource) -> String {
        let verb = switch command {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
        return """
            if application id "\(source.bundleID)" is running then
                tell application id "\(source.bundleID)" to \(verb)
            end if
            """
    }

    static func setShuffle(_ isOn: Bool, for source: MusicSource) -> String {
        let property = source == .spotify ? "shuffling" : "shuffle enabled"
        return """
            if application id "\(source.bundleID)" is running then
                tell application id "\(source.bundleID)" to set \(property) to \(isOn)
            end if
            """
    }

    static func seek(to seconds: TimeInterval, for source: MusicSource) -> String {
        let position = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
        return """
            if application id "\(source.bundleID)" is running then
                tell application id "\(source.bundleID)" to set player position to \(position)
            end if
            """
    }

    /// Parses the list returned by `state(for:)`. Returns nil when nothing is loaded.
    static func parseState(_ value: ScriptValue, source: MusicSource, at date: Date) -> PlaybackState? {
        guard let state = value[0].string, state != "stopped", let title = value[2].string else { return nil }
        let rawDuration = value[5].double ?? 0
        let track = Track(
            id: value[1].string ?? "",
            title: title,
            artist: value[3].string ?? "",
            album: value[4].string ?? "",
            // Spotify reports milliseconds, Music reports seconds.
            duration: source == .spotify ? rawDuration / 1000 : rawDuration,
            artworkURL: value[7].string.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            source: source
        )
        return PlaybackState(
            track: track,
            isPlaying: state == "playing",
            position: value[6].double ?? 0,
            sampledAt: date,
            isShuffling: value[8].bool
        )
    }
}
