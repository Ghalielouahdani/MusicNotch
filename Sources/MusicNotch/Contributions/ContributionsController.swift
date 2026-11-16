import Foundation
import Observation

/// Loads the Spotify activity shown in the contributions window.
@MainActor
@Observable
final class ContributionsController {
    enum Phase: Equatable {
        case idle
        case notConnected
        case loading(String)
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var events: [ContributionEvent] = []

    @ObservationIgnored private let auth: SpotifyAuth
    @ObservationIgnored private let source: SpotifyContributions
    @ObservationIgnored private var task: Task<Void, Never>?

    init(auth: SpotifyAuth) {
        self.auth = auth
        source = SpotifyContributions(auth: auth)
    }

    func refresh() {
        guard auth.status == .connected else {
            phase = .notConnected
            return
        }
        task?.cancel()
        task = Task { [weak self] in await self?.load() }
    }

    func forgetAccount() {
        task?.cancel()
        events = []
        phase = .idle
        source.forgetAccount()
    }

    /// Fake but plausible data, for `--snapshot` and design reviews.
    func showPreview() {
        events = Self.sampleEvents()
        phase = .loaded
    }

    private func load() async {
        phase = .loading("Connecting to Spotify…")
        do {
            let events = try await source.events { [weak self] message in
                self?.phase = .loading(message)
            }
            self.events = events
            phase = .loaded
        } catch is CancellationError {
            // A newer refresh took over.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    static func sampleEvents(today: Date = .now) -> [ContributionEvent] {
        let songs = [
            ("Midnight City", "M83"), ("Nightcall", "Kavinsky"), ("Wounder", "Burial"),
            ("A Real Hero", "College, Electric Youth"), ("Intro", "The xx"), ("Retrograde", "James Blake"),
            ("Breathe", "Télépopmusik"), ("Teardrop", "Massive Attack"), ("Genesis", "Justice"),
        ]
        let playlists = ["Late night drives", "Focus — deep work", "Summer '26", "Running"]
        var seed: UInt64 = 42
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }

        let calendar = Calendar.current
        var events: [ContributionEvent] = []
        for daysAgo in 0..<371 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let weekend = calendar.isDateInWeekend(day)
            // Busy streaks every few weeks, quieter in between.
            let busy = (daysAgo / 9) % 4 == 0
            let roll = random(100)
            guard roll < (busy ? 85 : weekend ? 55 : 35) else { continue }
            let count = 1 + random(busy ? 9 : 4)
            for index in 0..<count {
                let song = songs[random(songs.count)]
                let date = day.addingTimeInterval(TimeInterval(-index * 600))
                if random(3) == 0 {
                    events.append(ContributionEvent(date: date, kind: .liked, trackName: song.0, artist: song.1))
                } else {
                    events.append(ContributionEvent(
                        date: date, kind: .addedToPlaylist,
                        trackName: song.0, artist: song.1, playlistName: playlists[random(playlists.count)]
                    ))
                }
            }
            if random(60) == 0 {
                events.append(ContributionEvent(date: day, kind: .createdPlaylist, playlistName: playlists[random(playlists.count)]))
            }
        }
        return events
    }
}
