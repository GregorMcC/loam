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
            // The filter, the selection, and the checks belong to one plot, so a move to another plot starts them anew.
            case .intake(let plot): IntakeView(model: model, plotID: plot).id(plot)
            case .recurring(let plot): RecurringView(model: model, plotID: plot)
            case .desk: DeskView(model: model)
            case .metrics: MetricsView(model: model)
            case .today, nil: TodayView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LoamColor.horizonA)
    }
}

/// Today: the desk tiles, the line of each plot, the run events since you last left Today, and the run limits.
struct TodayView: View {
    let model: AppModel

    var body: some View {
        let today = model.today
        VStack(alignment: .leading, spacing: 0) {
            TodayHeader(model: model)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.runs.isEmpty {
                        EmptyRuns()
                    } else {
                        DeskTiles(tiles: today.tiles, deskCount: model.deskQueue.count, model: model)
                    }
                    if !today.line.isEmpty { TheLine(rows: today.line, model: model) }
                    TodayColumns(weights: [1.6, 1], gap: 28) {
                        AwayList(model: model)
                        if let limits = model.todayData.limits {
                            LimitsCard(rows: TodayWords.limits(limits, tries: RunDraft.defaultTries))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await model.readToday() }
        .task { await model.readUsage() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today")
    }
}

/// The title of Today, the day and the runs that work, Start a run, and Open the desk.
private struct TodayHeader: View {
    let model: AppModel

    var body: some View {
        let desk = model.deskQueue.count
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Today").font(.system(size: 13, weight: .semibold)).foregroundStyle(LoamColor.ink)
                Text(TodayWords.caption(runs: model.runs, limits: model.todayData.limits, now: model.now()))
                    .font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted)
                    .accessibilityIdentifier("today-caption")
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Start a run") { TodayActions.startRun(model) }
                .loamSecondaryButton()
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.startRunPlot == nil)
                .help("Open the intake of a plot, to start a run from an issue (\u{2318}R)")
                .accessibilityIdentifier("today-start-run")
            Button("Open the desk \u{00B7} \(desk)") { TodayActions.openDesk(model) }
                .loamPrimaryButton()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(desk == 0)
                .help("Decide on the runs that wait for you, one at a time (\u{2318}\u{21A9})")
                .accessibilityIdentifier("today-open-desk")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 56)
    }
}

/// The two actions of Today. The header and the action bar both call them.
@MainActor
enum TodayActions {
    static func openDesk(_ model: AppModel) {
        guard !model.deskQueue.isEmpty else { return }
        Task { await model.openDesk() }
    }

    static func startRun(_ model: AppModel) {
        guard let plot = model.startRunPlot else { return }
        Task { await model.showIntake(plot: plot) }
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

/// The title of a section of Today, with a caption after it on the same baseline.
private struct SectionTitle: View {
    let title: String
    var caption: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(LoamColor.inkFaint)
            if let caption {
                Text(caption).font(.system(size: 11)).foregroundStyle(LoamColor.inkFaint).lineLimit(1)
            }
        }
        .padding(.bottom, 8)
    }
}

/// The three desk tiles: Shape, Land, and Stopped. A click on a tile opens the desk on its first run.
private struct DeskTiles: View {
    let tiles: [TodayContent.Tile]
    let deskCount: Int
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Your desk", caption: TodayWords.deskCaption(count: deskCount))
            HStack(alignment: .top, spacing: 12) {
                ForEach(tiles, id: \.station) { tile in
                    Button { open(tile) } label: { TileView(tile: tile) }
                        .buttonStyle(.plain)
                        .disabled(tile.count == 0)
                        .accessibilityIdentifier("today-tile-\(tile.station.rawValue)")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The desk on the first run of the station. A run that is stopped by a limit is not at the desk, so its page
    /// opens.
    private func open(_ tile: TodayContent.Tile) {
        if let first = model.deskQueue.first(where: { $0.state.station == tile.station }) {
            Task { await model.openDesk(first.id) }
        } else if let run = tile.runs.first {
            Task { await model.openRun(run.runID) }
        }
    }
}

/// One desk tile: the mark, the station and its count, how long the runs wait, the first runs, and a line about them.
private struct TileView: View {
    let tile: TodayContent.Tile
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if tile.count > 0 { StationMark(station: tile.station) }
                Text("\(tile.station.words) \(tile.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tile.count > 0 ? LoamColor.ink : LoamColor.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let age = tile.age {
                    Text(age).font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted)
                }
            }
            ForEach(tile.runs) { run in
                Text(run.words).font(.system(size: 12)).foregroundStyle(LoamColor.ink)
            }
            if let context = tile.context {
                Text(context)
                    .font(.system(size: tile.contextStops ? 12 : 11))
                    .foregroundStyle(tile.contextStops ? LoamColor.rust : LoamColor.inkMuted)
            }
            if tile.count == 0 {
                Text("None").font(.system(size: 11)).foregroundStyle(LoamColor.inkFaint)
            }
        }
        .lineLimit(1)
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 12, trailing: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(hovering && tile.count > 0 ? LoamColor.inkFill : Color.clear, in: RoundedRectangle(cornerRadius: LoamTheme.radiusMd))
        .background(LoamColor.horizonB, in: RoundedRectangle(cornerRadius: LoamTheme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: LoamTheme.radiusMd).strokeBorder(LoamColor.inkHairline))
        .contentShape(RoundedRectangle(cornerRadius: LoamTheme.radiusMd))
        .onHover { hovering = $0 }
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

/// The line: one row for each plot with runs or intake, with its intake, a chip for each run at its station, and
/// the runs that landed this week.
private struct TheLine: View {
    let rows: [TodayContent.LineRow]
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "The line", caption: "Every plot's runs, by station")
            TodayColumns(lead: 150, weights: Array(repeating: 1, count: 6), gap: 10) {
                ForEach(["Plot", "Intake"] + TodayContent.lineStations.map(\.words) + [RunStation.landed.words], id: \.self) {
                    Text($0)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(LoamColor.inkFaint).lineLimit(1)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { LoamColor.rule.frame(height: 1) }
                }
            }
            ForEach(rows) { row in
                TodayColumns(lead: 150, weights: Array(repeating: 1, count: 6), gap: 10) {
                    LineCell {
                        Text(row.plotName).font(.system(size: 13, weight: .semibold)).foregroundStyle(LoamColor.ink)
                        Caption(text: row.caption)
                    }
                    // The intake of the plot opens its Intake page (TAS-44).
                    Button { Task { await model.showIntake(plot: row.plotID) } } label: {
                        LineCell {
                            if let intake = row.intake {
                                if intake.none {
                                    None()
                                } else {
                                    Text(intake.count).font(.system(size: 13)).foregroundStyle(LoamColor.ink)
                                }
                                if let caption = intake.caption { Caption(text: caption) }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open the intake of \(row.plotName)")
                    .accessibilityIdentifier("today-intake-\(row.plotID)")
                    ForEach(TodayContent.lineStations, id: \.self) { station in
                        LineCell {
                            let chips = row.chips[station] ?? []
                            if chips.isEmpty { None() }
                            ForEach(chips) { chip in ChipView(chip: chip) { open(chip) } }
                        }
                    }
                    LineCell {
                        if row.landed > 0 {
                            Text("\(row.landed) landed").font(.system(size: 13)).foregroundStyle(LoamColor.ink)
                        } else {
                            None()
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("today-line-\(row.plotID)")
            }
        }
    }

    /// The desk for a run that waits there, else the run page.
    private func open(_ chip: TodayContent.Chip) {
        Task { await model.openWaitingRun(chip.runID) }
    }

    private struct Caption: View {
        let text: String
        var body: some View { Text(text).font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted) }
    }

    private struct None: View {
        var body: some View { Text("None").font(.system(size: 11)).foregroundStyle(LoamColor.inkFaint) }
    }
}

/// A cell of the line: its content from the top, and a hairline under it.
private struct LineCell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5, content: content)
            .lineLimit(1)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 62, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottom) { LoamColor.inkHairline.frame(height: 1) }
    }
}

/// One run on the line: its mark, its PR or key in mono (else its title), and a short state. A run that waits for a
/// slot has a dashed edge and no ground.
private struct ChipView: View {
    let chip: TodayContent.Chip
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch chip.mark {
                case .needsYou: AttentionDot(mark: .needs).frame(width: 8, height: 8)
                case .doneUnread: AttentionDot(mark: .unread).frame(width: 8, height: 8)
                case .none: EmptyView()
                }
                if !chip.key.isEmpty {
                    Text(chip.key).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(LoamColor.inkMuted)
                } else if chip.state != chip.title {
                    Text(chip.title).font(.system(size: 11.5)).foregroundStyle(LoamColor.inkMuted).layoutPriority(-1)
                }
                Text(chip.state)
                    .font(.system(size: 11.5))
                    .foregroundStyle(chip.stopped ? LoamColor.rust : chip.waits ? LoamColor.inkMuted : LoamColor.ink)
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ground, in: RoundedRectangle(cornerRadius: LoamTheme.radiusSm))
            .overlay {
                if chip.waits {
                    RoundedRectangle(cornerRadius: LoamTheme.radiusSm).strokeBorder(LoamColor.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                } else {
                    RoundedRectangle(cornerRadius: LoamTheme.radiusSm).strokeBorder(LoamColor.inkHairline)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: LoamTheme.radiusSm))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(chip.title)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-chip-\(chip.runID)")
    }

    private var ground: Color {
        if hovering { return LoamColor.inkSelected }
        return chip.waits ? .clear : LoamColor.horizonB
    }
}

/// While you were away: the run events since you last left Today, the newest first.
private struct AwayList: View {
    let model: AppModel

    var body: some View {
        let now = model.now()
        let rows = TodayWords.away(model.todayData.awayEvents, now: now)
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "While you were away", caption: model.todayData.awaySince.map {
                TodayWords.awayCaption(since: $0, empty: rows.isEmpty, now: now)
            })
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.time).foregroundStyle(LoamColor.inkFaint).monospacedDigit()
                        .frame(width: 44, alignment: .leading)
                    Text("\(row.title): \(Text(row.detail).foregroundStyle(row.stopped ? LoamColor.rust : LoamColor.ink))")
                        .foregroundStyle(LoamColor.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
                .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-away")
    }
}

/// The run limits that hold for every run.
private struct LimitsCard: View {
    let rows: [TodayWords.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Limits").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(LoamColor.ink)
            ForEach(rows, id: \.label) { row in
                HStack {
                    Text(row.label).foregroundStyle(LoamColor.inkMuted)
                    Spacer(minLength: 8)
                    Text(row.value).foregroundStyle(LoamColor.ink)
                }
                .font(.system(size: 12))
            }
        }
        .lineLimit(1)
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: LoamTheme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: LoamTheme.radiusMd).strokeBorder(LoamColor.inkHairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-limits")
    }
}

/// Columns side by side: a first column of a fixed width when `lead` is set, then columns that share the rest by
/// their weights. Each column gets the height of the tallest, and its content starts at the top.
private struct TodayColumns: Layout {
    var lead: CGFloat?
    var weights: [CGFloat]
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let widths = columnWidths(width, count: subviews.count)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, columnWidths(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gap
        }
    }

    private func columnWidths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let shared = Array(weights.prefix(count - (lead == nil ? 0 : 1)))
        let rest = total - (lead ?? 0) - gap * CGFloat(max(count - 1, 0))
        let sum = max(shared.reduce(0, +), 1)
        return (lead.map { [$0] } ?? []) + shared.map { max(rest * $0 / sum, 0) }
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
                // One step back (TAS-46). With no place before, it goes to Today.
                Button { Task { await model.runPageBack() } } label: {
                    Label("Back", systemImage: "chevron.left").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("run-page-back")
                if let run {
                    RunHeader(run: run, plotName: model.plots.first { $0.id == run.plotID }?.name ?? "", model: model)
                    RunGroupLinks(model: model, run: run)
                    if let error = model.fixError, error.run == run.id {
                        Text(error.message).loamText(LoamTheme.bodyStyle, LoamColor.rust).textSelection(.enabled)
                            .padding(LoamTheme.space4).frame(maxWidth: .infinity, alignment: .leading)
                            .loamCard(LoamColor.rustWash)
                            .accessibilityIdentifier("run-page-fix-error")
                    }
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
        TodayWords.eventWords(kind: event.kind, detail: event.detail)
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
            // TAS-176: a run that fixes a landed run counts it as a change failure on the Metrics page.
            if run.state == .landed {
                Button("Fix this") { Task { await model.fixRun(run.id) } }
                    .loamSecondaryButton()
                    .disabled(model.isStartingRun)
                    .help("Have Claude draft a run that fixes this one. The draft waits at the desk.")
                    .accessibilityIdentifier("run-page-fix")
            }
            if atDesk {
                Button("Watch") { model.watchRun(run) }
                    .loamSecondaryButton()
                    .disabled(run.shortSessionID == nil)
                    .help(watchHelp)
                    .accessibilityIdentifier("run-page-watch")
                // A run that waits for you goes to the desk, where you approve, send back, or merge it.
                Button("Open at the desk") { Task { await model.openDesk(run.id) } }
                    .loamPrimaryButton()
                    .accessibilityIdentifier("run-page-desk")
            } else {
                Button("Watch") { model.watchRun(run) }
                    .loamPrimaryButton()
                    .disabled(run.shortSessionID == nil)
                    .help(watchHelp)
                    .accessibilityIdentifier("run-page-watch")
            }
        }
    }

    private var atDesk: Bool { model.deskQueue.contains { $0.id == run.id } }

    private var watchHelp: String {
        run.shortSessionID == nil ? "The session has not started." : "Open the session in a tab with claude attach."
    }

    private var headline: String {
        var parts = [plotName, run.state.words]
        if let source = run.source { parts.append(source.label) }
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
