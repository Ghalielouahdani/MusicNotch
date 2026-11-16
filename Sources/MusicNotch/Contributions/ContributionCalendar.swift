import Foundation

/// One thing the user did in Spotify, with the day it happened.
struct ContributionEvent: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The user added a song to one of their playlists (`added_at` + `added_by`).
        case addedToPlaylist
        /// The user liked a song (`added_at` of Liked Songs).
        case liked
        /// Spotify has no creation date for playlists: this is the earliest `added_at` in it.
        case createdPlaylist
    }

    let date: Date
    let kind: Kind
    var trackName: String?
    var artist: String?
    var playlistName: String?
}

/// Which events the grid counts.
enum ContributionFilter: String, CaseIterable, Identifiable {
    case all, playlists, liked

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .playlists: "Playlists"
        case .liked: "Liked Songs"
        }
    }

    func includes(_ event: ContributionEvent) -> Bool {
        switch self {
        case .all: true
        case .playlists: event.kind != .liked
        case .liked: event.kind == .liked
        }
    }
}

/// The last year laid out like GitHub's contribution graph: one column per week,
/// one row per weekday, today in the last column.
struct ContributionCalendar {
    struct Day: Identifiable, Hashable {
        let date: Date
        let events: [ContributionEvent]
        var count: Int { events.count }
        var id: Date { date }
    }

    /// Columns of 7 days. Days after today are `nil`.
    let weeks: [[Day?]]
    let total: Int
    let longestStreak: Int
    let currentStreak: Int
    let busiestDay: Day?
    let calendar: Calendar
    /// Upper bounds of levels 1, 2 and 3 (level 4 is everything above).
    private let thresholds: [Int]

    init(events: [ContributionEvent], today: Date = .now, calendar: Calendar = .current) {
        self.calendar = calendar
        let end = calendar.startOfDay(for: today)
        let yearAgo = calendar.date(byAdding: .weekOfYear, value: -52, to: end)!
        let start = calendar.dateInterval(of: .weekOfYear, for: yearAgo)?.start ?? yearAgo

        let byDay = Dictionary(grouping: events.filter { $0.date >= start }) { calendar.startOfDay(for: $0.date) }

        var days: [Day] = []
        var cursor = start
        while cursor <= end {
            days.append(Day(date: cursor, events: (byDay[cursor] ?? []).sorted { $0.date > $1.date }))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }

        var weeks: [[Day?]] = stride(from: 0, to: days.count, by: 7).map { index in
            days[index..<min(index + 7, days.count)].map { Optional($0) }
        }
        if let last = weeks.indices.last {
            weeks[last] += Array(repeating: nil, count: 7 - weeks[last].count)
        }
        self.weeks = weeks

        total = days.reduce(0) { $0 + $1.count }
        busiestDay = days.max { $0.count < $1.count }.flatMap { $0.count > 0 ? $0 : nil }

        var longest = 0, run = 0
        for day in days {
            run = day.count > 0 ? run + 1 : 0
            longest = max(longest, run)
        }
        longestStreak = longest
        // Today without activity yet doesn't break the streak, like on GitHub.
        let streakDays = days.last?.count == 0 ? days.dropLast() : days[...]
        currentStreak = streakDays.reversed().prefix { $0.count > 0 }.count

        // Quartiles of the active days, so one huge day doesn't flatten the rest.
        let counts = days.map(\.count).filter { $0 > 0 }.sorted()
        if counts.isEmpty {
            thresholds = [1, 2, 3]
        } else {
            thresholds = [0.25, 0.5, 0.75].map { counts[min(counts.count - 1, Int(Double(counts.count) * $0))] }
        }
    }

    /// 0 (nothing) to 4 (busiest), like GitHub's five shades.
    func level(for count: Int) -> Int {
        guard count > 0 else { return 0 }
        if count <= thresholds[0] { return 1 }
        if count <= thresholds[1] { return 2 }
        if count <= thresholds[2] { return 3 }
        return 4
    }

    /// Week columns that start a new month, with the month's short name.
    var monthLabels: [Int: String] {
        var labels: [Int: String] = [:]
        var lastMonth: Int?
        for (index, week) in weeks.enumerated() {
            guard let first = week.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: first.date)
            if month != lastMonth {
                // Skip a label squeezed into the very first column; the next one would overlap it.
                if lastMonth != nil || calendar.component(.day, from: first.date) <= 7 {
                    labels[index] = calendar.shortMonthSymbols[month - 1]
                }
                lastMonth = month
            }
        }
        return labels
    }

    /// Short weekday names in row order, honoring the locale's first weekday.
    var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}
