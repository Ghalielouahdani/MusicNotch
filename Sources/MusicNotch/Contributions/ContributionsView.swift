import SwiftUI

/// GitHub-style contribution graph of the user's Spotify activity.
struct ContributionsView: View {
    @Bindable var model: ContributionsController
    var connectSpotify: () -> Void = {}

    @State private var filter: ContributionFilter = .all
    @State private var hovered: ContributionCalendar.Day?
    @State private var selected: ContributionCalendar.Day?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .loaded:
                content(ContributionCalendar(events: model.events.filter { filter.includes($0) }))
            case .idle, .loading:
                placeholder {
                    ProgressView().controlSize(.small)
                    if case .loading(let message) = model.phase {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
            case .notConnected:
                placeholder {
                    Text("Connect Spotify to see your activity.").foregroundStyle(.secondary)
                    Button("Connect Spotify", action: connectSpotify).buttonStyle(.borderedProminent)
                }
            case .failed(let message):
                placeholder {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try Again") { model.refresh() }
                }
            }
        }
        .padding(20)
        .frame(width: ContributionGrid.width + 40, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func content(_ calendar: ContributionCalendar) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(calendar.total.formatted()) contributions in the last year")
                .font(.title3.weight(.semibold))
            Spacer()
            Picker("Show", selection: $filter) {
                ForEach(ContributionFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload from Spotify")
        }

        VStack(alignment: .leading, spacing: 8) {
            ContributionGrid(calendar: calendar, hovered: $hovered, selected: $selected)
            HStack {
                Text(caption(calendar))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Legend()
            }
            .font(.caption)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))

        HStack(spacing: 12) {
            Stat(value: calendar.total.formatted(), label: "Contributions")
            Stat(value: "\(calendar.longestStreak) days", label: "Longest streak")
            Stat(value: "\(calendar.currentStreak) days", label: "Current streak")
            Stat(
                value: calendar.busiestDay.map { "\($0.count)" } ?? "—",
                label: calendar.busiestDay.map { "Busiest day · \($0.date.formatted(.dateTime.month().day()))" } ?? "Busiest day"
            )
        }

        if let selected {
            DayDetail(day: selected) { self.selected = nil }
        }
    }

    private func caption(_ calendar: ContributionCalendar) -> String {
        guard let day = hovered ?? selected else { return "Hover a square to see the day. Click it for details." }
        let date = day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        switch day.count {
        case 0: return "No contributions on \(date)"
        case 1: return "1 contribution on \(date)"
        default: return "\(day.count) contributions on \(date)"
        }
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 12, content: content)
            .frame(maxWidth: .infinity, minHeight: 180)
    }
}

// MARK: Grid

private struct ContributionGrid: View {
    static let cell: CGFloat = 11
    static let gap: CGFloat = 3
    static let labelWidth: CGFloat = 28
    static let columns = 53
    static var width: CGFloat { labelWidth + CGFloat(columns) * (cell + gap) + 28 }

    let calendar: ContributionCalendar
    @Binding var hovered: ContributionCalendar.Day?
    @Binding var selected: ContributionCalendar.Day?

    var body: some View {
        let months = calendar.monthLabels
        let weekdays = calendar.weekdaySymbols
        VStack(alignment: .leading, spacing: 4) {
            // Month names above the first column of each month.
            HStack(spacing: Self.gap) {
                Color.clear.frame(width: Self.labelWidth - Self.gap, height: 1)
                ForEach(calendar.weeks.indices, id: \.self) { index in
                    Text(months[index] ?? "")
                        .fixedSize()
                        .frame(width: Self.cell, alignment: .leading)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: Self.gap) {
                // Every other weekday, like GitHub.
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row.isMultiple(of: 2) ? "" : weekdays[row])
                            .frame(width: Self.labelWidth - Self.gap, height: Self.cell, alignment: .leading)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                ForEach(calendar.weeks.indices, id: \.self) { column in
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { row in
                            if let day = calendar.weeks[column][row] {
                                cell(day)
                            } else {
                                Color.clear.frame(width: Self.cell, height: Self.cell)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ day: ContributionCalendar.Day) -> some View {
        let isSelected = selected == day
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(ContributionPalette.color(level: calendar.level(for: day.count)))
            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(.primary, lineWidth: isSelected ? 1.5 : 0))
            .frame(width: Self.cell, height: Self.cell)
            .scaleEffect(hovered == day ? 1.25 : 1)
            .animation(.spring(duration: 0.2), value: hovered == day)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = day } else if hovered == day { hovered = nil }
            }
            .onTapGesture { selected = isSelected ? nil : day }
    }
}

enum ContributionPalette {
    /// Spotify green, from faint to full.
    static func color(level: Int) -> Color {
        let green = Color(red: 0.11, green: 0.73, blue: 0.33)
        switch level {
        case 0: return Color.primary.opacity(0.07)
        case 1: return green.opacity(0.3)
        case 2: return green.opacity(0.55)
        case 3: return green.opacity(0.8)
        default: return green
        }
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("Less").padding(.trailing, 2)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(ContributionPalette.color(level: level))
                    .frame(width: 11, height: 11)
            }
            Text("More").padding(.leading, 2)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: Stats and details

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

private struct DayDetail: View {
    let day: ContributionCalendar.Day
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            if day.events.isEmpty {
                Text("Nothing that day.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(day.events.enumerated()), id: \.offset) { _, event in
                        EventRow(event: event)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

private struct EventRow: View {
    let event: ContributionEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(event.kind == .liked ? .pink : .green)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch event.kind {
        case .addedToPlaylist: "plus.circle.fill"
        case .liked: "heart.fill"
        case .createdPlaylist: "sparkles"
        }
    }

    private var title: String {
        switch event.kind {
        case .createdPlaylist: "Created \(event.playlistName ?? "a playlist")"
        default: [event.trackName, event.artist].compactMap { $0 }.joined(separator: " — ")
        }
    }

    private var subtitle: String {
        switch event.kind {
        case .addedToPlaylist: "Added to \(event.playlistName ?? "a playlist")"
        case .liked: "Added to Liked Songs"
        case .createdPlaylist: "Date of its first song (Spotify doesn't share creation dates)"
        }
    }
}
