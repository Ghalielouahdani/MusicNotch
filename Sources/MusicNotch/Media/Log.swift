import os

/// `log stream --predicate 'subsystem == "com.ghalielouahdani.MusicNotch"' --level info`
enum Log {
    static let media = Logger(subsystem: "com.ghalielouahdani.MusicNotch", category: "media")
    static let playlists = Logger(subsystem: "com.ghalielouahdani.MusicNotch", category: "playlists")
    static let spotify = Logger(subsystem: "com.ghalielouahdani.MusicNotch", category: "spotify")
}
