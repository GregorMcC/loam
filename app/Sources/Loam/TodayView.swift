import LoamKit
import SwiftUI

/// The page in the well (ticket 203): Today, or one run. The window shows it in place of the tabs and
/// panes while `AppModel.page` is set.
struct PageView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.page {
            case .run(let id): RunPageView(model: model, id: id)
            case .intake(let plot): IntakeView(model: model, plotID: plot)
            case .desk: DeskView(model: model)
            case .today, nil: TodayView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LoamColor.horizonA)
    }
}

/// Today: the desk tiles, the line of each plot, and the runs that moved last.
struct TodayView: View {
    let model: AppModel

    var body: some View {
        let today = model.today
        ScrollView {
            VStack(alignment: .leading, spacing: LoamTheme.space6) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today").loamText(LoamTheme.plotNameStyle)
                    Text(subtitle(today)).loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                }
                if model.runs.isEmpty {
                    EmptyRuns()
                } else {
                    DeskTiles(tiles: today.tiles, model: model)
                    if !today.needsYou.isEmpty {
                        RunSection(title: "Needs you", items: today.needsYou, model: model, id: "today-needs-you")
                    }
                    TheLine(rows: today.line)
                    RunSection(title: "Runs", items: today.recent, model: model, id: "today-recent")
                }
            }
            .padding(LoamTheme.space8)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today")
    }

    private func subtitle(_ today: TodayContent) -> String {
        switch today.needsYouCount {
        case 0: "No run needs you."
        case 1: "1 run needs you."
        case let n: "\(n) runs need you."
        }
    }
}

/// What Today shows before the first run.
private struct EmptyRuns: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text("No runs yet").loamText(LoamTheme.rowStyle)
            Text("A run is one goal that a background session works on in a worktree, until its checks pass. Start one in a terminal:")
                .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
            Text("loam run start <plot> --title <text> --check <name>=<command>")
                .loamText(LoamTheme.codeStyle, LoamColor.ink)
                .textSelection(.enabled)
        }
        .padding(LoamTheme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loamCard()
        .accessibilityIdentifier("today-empty")
    }
}

/// The three desk tiles: Shape, Land, and Stopped. A click on Land or Stopped opens the desk on its first run.
private struct DeskTiles: View {
    let tiles: [TodayContent.Tile]
    let model: AppModel

    var body: some View {
        HStack(spacing: LoamTheme.space3) {
            ForEach(tiles, id: \.station) { tile in
                let first = model.deskQueue.first { $0.state.station == tile.station }
                Button { Task { await model.openDesk(first?.id) } } label: { content(tile) }
                    .buttonStyle(.plain)
                    .disabled(first == nil)
                    .accessibilityIdentifier("today-tile-\(tile.station.rawValue)")
            }
        }
    }

    private func content(_ tile: TodayContent.Tile) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            HStack(spacing: 6) {
                if tile.count > 0 { StationMark(station: tile.station) }
                Text(tile.station.words)
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            }
            Text("\(tile.count)")
                .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tile.count > 0 ? LoamColor.ink : LoamColor.inkFaint)
        }
        .padding(LoamTheme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loamCard()
        .contentShape(Rectangle())
    }
}

/// The mark of a station that waits for you: the Needs you dot for Shape and Stopped, and the Done,
/// unread ring for a run that is ready. These are the only two attention signals.
private struct StationMark: View {
    let station: RunStation
    var body: some View {
        switch station {
        case .shape, .stopped: AttentionDot(mark: .needs).frame(width: 8, height: 8)
        case .land: AttentionDot(mark: .unread).frame(width: 8, height: 8)
        case .run, .ship, .landed: EmptyView()
        }
    }
}

/// The line: one row for each plot with runs, with a count at each station.
private struct TheLine: View {
    let rows: [TodayContent.LineRow]

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text("The line").loamLabel()
            Grid(alignment: .leading, horizontalSpacing: LoamTheme.space4, verticalSpacing: 0) {
                GridRow {
                    Text("Plot").loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                    ForEach(TodayContent.lineStations, id: \.self) { station in
                        Text(station.words).loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                            .gridColumnAlignment(.trailing)
                    }
                }
                .padding(.vertical, 6)
                ForEach(rows) { row in
                    Divider().overlay(LoamColor.inkHairline)
                    GridRow {
                        Text(row.plotName).loamText(LoamTheme.rowStyle).lineLimit(1)
                        ForEach(TodayContent.lineStations, id: \.self) { station in
                            let n = row.counts[station] ?? 0
                            Text(n > 0 ? "\(n)" : "\u{00B7}")
                                .font(.system(size: 13)).monospacedDigit()
                                .foregroundStyle(n > 0 ? LoamColor.ink : LoamColor.inkFaint)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("today-line-\(row.plotID)")
                }
            }
            .padding(.horizontal, LoamTheme.space4)
            .padding(.vertical, LoamTheme.space2)
            .loamCard()
        }
    }
}

/// A titled list of runs. A click opens the run page.
private struct RunSection: View {
    let title: String
    let items: [TodayContent.Item]
    let model: AppModel
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text(title).loamLabel()
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(LoamColor.inkHairline) }
                    RunRow(item: item) { Task { await model.openRun(item.run.id) } }
                }
            }
            .loamCard()
        }
        // A container, so each row keeps its own ID.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}

/// One run in a list: its mark, its title, its plot and state, its tries, and when it moved.
private struct RunRow: View {
    let item: TodayContent.Item
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: LoamTheme.space3) {
                RunMark(state: item.run.state).frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.run.title).loamText(LoamTheme.rowStyle).lineLimit(1)
                    Text("\(item.plotName) \u{00B7} \(item.run.state.words)")
                        .loamText(LoamTheme.captionStyle, LoamColor.inkMuted).lineLimit(1)
                }
                Spacer(minLength: LoamTheme.space2)
                if !item.run.doneWhen.isEmpty || item.run.tries > 0 {
                    Text("try \(min(item.run.tries + 1, item.run.maxTries)) of \(item.run.maxTries)")
                        .loamText(LoamTheme.captionStyle, LoamColor.inkFaint).monospacedDigit()
                }
                Text(item.when).loamText(LoamTheme.captionStyle, LoamColor.inkFaint).monospacedDigit()
            }
            .padding(.horizontal, LoamTheme.space4)
            .frame(height: 48)
            .background(hovering ? LoamColor.inkFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("run-row-\(item.run.id)")
    }
}

/// The mark of a run state: Needs you, Done, unread for Ready, a spinner glyph while it runs or ships, and
/// nothing once it left the line.
private struct RunMark: View {
    let state: RunState
    var body: some View {
        if state.needsYou {
            AttentionDot(mark: .needs).frame(width: 8, height: 8)
        } else if state == .ready {
            AttentionDot(mark: .unread).frame(width: 8, height: 8)
        } else if state.station == .run || state.station == .ship {
            Image(systemName: "circle.dotted").font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted)
        } else {
            Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(LoamColor.inkFaint)
        }
    }
}

/// The page of one run: its state, its goal and checks, its history, and Watch and Stop.
struct RunPageView: View {
    let model: AppModel
    let id: String

    var body: some View {
        let run = model.runStatus?.run.id == id ? model.runStatus?.run : model.runs.first { $0.id == id }
        ScrollView {
            VStack(alignment: .leading, spacing: LoamTheme.space6) {
                Button { model.showToday() } label: {
                    Label("Today", systemImage: "chevron.left").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("run-page-back")
                if let run {
                    RunHeader(run: run, plotName: model.plots.first { $0.id == run.plotID }?.name ?? "", model: model)
                    if !run.note.isEmpty {
                        Text(run.note).loamText(LoamTheme.bodyStyle, LoamColor.ink).textSelection(.enabled)
                            .padding(LoamTheme.space4).frame(maxWidth: .infinity, alignment: .leading).loamCard()
                            .accessibilityIdentifier("run-page-note")
                    }
                    if !run.goal.isEmpty {
                        PageSection(title: "Goal") {
                            Text(run.goal).loamText(LoamTheme.briefStyle).textSelection(.enabled)
                        }
                    }
                    PageSection(title: "Done when") {
                        if run.doneWhen.isEmpty {
                            Text("No checks. The run is done when the session ends a turn with its work committed.")
                                .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                        }
                        ForEach(run.doneWhen, id: \.name) { check in
                            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
                                Text(check.name).loamText(LoamTheme.rowStyle).frame(width: 140, alignment: .leading)
                                Text(check.command).loamText(LoamTheme.codeStyle, LoamColor.inkMuted).textSelection(.enabled)
                            }
                        }
                    }
                    if let events = model.runStatus?.run.id == id ? model.runStatus?.events : nil {
                        PageSection(title: "History") {
                            ForEach(events) { event in
                                HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
                                    Text(ChangeRules.clock(event.at)).loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                                        .monospacedDigit().frame(width: 44, alignment: .leading)
                                    Text(eventWords(event)).loamText(LoamTheme.bodyStyle, LoamColor.ink)
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("run-page-history")
                    }
                } else {
                    Text("This run is gone.").loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                }
            }
            .padding(LoamTheme.space8)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run-page")
    }

    private func eventWords(_ event: RunEvent) -> String {
        switch event.kind {
        case "state": RunState(rawValue: event.detail)?.words ?? event.detail
        case "try": event.detail.isEmpty ? "A try failed" : event.detail
        default: event.detail
        }
    }
}

/// The title, the plot and state line, and the actions of a run.
private struct RunHeader: View {
    let run: Run
    let plotName: String
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: LoamTheme.space4) {
            VStack(alignment: .leading, spacing: 6) {
                Text(run.title).loamText(LoamTheme.plotNameStyle).textSelection(.enabled)
                HStack(spacing: 6) {
                    RunMark(state: run.state).frame(width: 12)
                    Text(headline).loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("run-page-state")
            }
            Spacer(minLength: LoamTheme.space4)
            if let pr = run.pr, let url = URL(string: pr.url) {
                Button("Open #\(pr.number)") { NSWorkspace.shared.open(url) }
                    .loamSecondaryButton()
                    .help(pr.url)
                    .accessibilityIdentifier("run-page-pr")
            }
            if !run.state.ended {
                Button("Stop run") { Task { await model.stopRun(run.id) } }
                    .loamSecondaryButton()
                    .accessibilityIdentifier("run-page-stop")
            }
            Button("Watch") { model.watchRun(run) }
                .loamPrimaryButton()
                .disabled(run.shortSessionID == nil)
                .help(run.shortSessionID == nil ? "The session has not started." : "Open the session in a tab with claude attach.")
                .accessibilityIdentifier("run-page-watch")
        }
    }

    private var headline: String {
        var parts = [plotName, run.state.words]
        if let source = run.source { parts.append(source.key) }
        if let pr = run.pr { parts.append("#\(pr.number)") }
        parts.append("\(run.tries) of \(run.maxTries) tries used")
        return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}

/// A labelled block of the run page.
private struct PageSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text(title).loamLabel()
            VStack(alignment: .leading, spacing: LoamTheme.space2, content: content)
                .padding(LoamTheme.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .loamCard()
        }
    }
}
