import LoamKit
import SwiftUI

/// The Metrics page (TAS-176): where the time of the runs goes, from approve to landed, in the last 30 days against
/// the 30 days before. The four tiles follow the DORA keys. The bar splits the lead time by station.
struct MetricsView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoamTheme.space6) {
                header
                if let metrics = model.metrics {
                    if metrics.current.landed == 0 {
                        Text("No run landed in the last \(MetricsWords.windowDays(metrics.current)) days. "
                             + "A run counts here when you land it.")
                            .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                            .accessibilityIdentifier("metrics-empty")
                    } else {
                        tiles(metrics)
                        StationBar(period: metrics.current)
                        details(metrics.current)
                        slowest(metrics.current)
                    }
                }
            }
            .padding(LoamTheme.space8)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("metrics")
    }

    private var plotName: String? {
        model.metricsPlot.flatMap { id in model.plots.first { $0.id == id }?.name }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: LoamTheme.space4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(MetricsWords.pageTitle(plot: plotName)).loamText(LoamTheme.rowStyle)
                Text("Where the time of your runs goes, from approve to landed. The last 30 days, against the 30 days before.")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LoamTheme.space1)
            }
            Spacer(minLength: LoamTheme.space4)
            Picker("Plot", selection: Binding(
                get: { model.metricsPlot ?? "" },
                set: { id in Task { await model.showMetrics(plot: id.isEmpty ? nil : id) } }
            )) {
                Text("All plots").tag("")
                ForEach(model.plots) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("metrics-plot")
        }
    }

    private func tiles(_ metrics: RunMetrics) -> some View {
        let now = metrics.current, before = metrics.previous
        return HStack(alignment: .top, spacing: LoamTheme.space3) {
            MetricTile(title: "Lead time", value: MetricsWords.duration(now.leadTime.medianSeconds),
                       lines: ["90th \(MetricsWords.duration(now.leadTime.p90Seconds))", MetricsWords.trend(metrics) ?? ""],
                       id: "metrics-lead")
            MetricTile(title: "Landed", value: "\(now.landed)",
                       lines: [MetricsWords.perWeek(now), "\(before.landed) in the \(MetricsWords.windowDays(before)) days before"],
                       id: "metrics-landed")
            MetricTile(title: "Fixed later", value: MetricsWords.share(now.fixed, of: now.landed),
                       lines: ["Runs that a later run fixes", "First pass: \(MetricsWords.share(now.firstPass, of: now.landed))"],
                       id: "metrics-fixed")
            MetricTile(title: "Recovery", value: now.recovery.gate.count > 0 ? MetricsWords.duration(now.recovery.gate.medianSeconds) : "None",
                       lines: ["From a failed gate to a pass", "CI: \(MetricsWords.spread(now.recovery.ci))"],
                       id: "metrics-recovery")
        }
        // The tiles take the height of the tallest one.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func details(_ period: MetricsPeriod) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text("Stations").loamLabel()
            ForEach(MetricsWords.stations(period), id: \.name) { station in
                DetailRow(name: station.name, value: MetricsWords.spread(station.spread))
            }
            DetailRow(name: "Approve", value: MetricsWords.approve(period.stations.approve))
            DetailRow(name: "Rework", value: MetricsWords.rework(period.rework))
            DetailRow(name: "Not landed", value: MetricsWords.notLanded(period.notLanded))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("metrics-stations")
    }

    @ViewBuilder
    private func slowest(_ period: MetricsPeriod) -> some View {
        if !period.slowest.isEmpty {
            VStack(alignment: .leading, spacing: LoamTheme.space2) {
                Text("Slowest runs").loamLabel()
                VStack(spacing: 0) {
                    ForEach(period.slowest, id: \.runID) { run in
                        SlowRunRow(run: run, plotName: model.metricsPlot == nil ? model.plots.first { $0.id == run.plotID }?.name : nil) {
                            Task { await model.openRun(run.runID) }
                        }
                    }
                }
                .loamCard()
            }
        }
    }
}

/// One key number with two lines under it.
private struct MetricTile: View {
    let title: String
    let value: String
    let lines: [String]
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space1) {
            Text(title).loamLabel()
            Text(value).loamText(LoamTheme.plotNameStyle).monospacedDigit()
            ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
                Text(line).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LoamTheme.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .loamCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

/// The median lead time as one bar, split by station. The station that holds the most time is moss, and the others
/// are tints of ink, so the bar adds no colour of its own.
private struct StationBar: View {
    let period: MetricsPeriod

    var body: some View {
        let stations = MetricsWords.stations(period).filter { $0.share > 0 }
        let top = MetricsWords.slowestStation(period)
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text("Lead time by station").loamLabel()
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(stations, id: \.name) { station in
                        RoundedRectangle(cornerRadius: LoamTheme.radiusXs)
                            .fill(station.name == top?.name ? LoamColor.moss : LoamColor.ink.opacity(0.16))
                            .frame(width: max(2, (geometry.size.width - CGFloat(stations.count - 1) * 2) * station.share))
                            .help("\(station.name): \(MetricsWords.duration(station.spread.medianSeconds))")
                    }
                }
            }
            .frame(height: 12)
            HStack(spacing: LoamTheme.space4) {
                ForEach(stations, id: \.name) { station in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(station.name == top?.name ? LoamColor.moss : LoamColor.ink.opacity(0.16))
                            .frame(width: 8, height: 8)
                        Text("\(station.name) \(MetricsWords.duration(station.spread.medianSeconds))")
                            .loamText(LoamTheme.captionStyle, LoamColor.inkMuted).monospacedDigit()
                    }
                }
            }
            if let top {
                Text(topNote(top)).loamText(LoamTheme.bodyStyle, LoamColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LoamTheme.space1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("metrics-bar")
    }

    private func topNote(_ top: MetricsWords.Station) -> String {
        switch top.name {
        case "Merge": "Most of the time is in Merge: the runs wait for you to land them."
        case "Queue": "Most of the time is in Queue: the runs wait for a slot or for your usage."
        case "Stopped": "Most of the time is in Stopped: the runs wait for you to start them again."
        default: "Most of the time is in \(top.name)."
        }
    }
}

/// A name and its value, in two columns.
private struct DetailRow: View {
    let name: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
            Text(name).loamText(LoamTheme.rowStyle).frame(width: 110, alignment: .leading)
            Text(value).loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).monospacedDigit()
        }
    }
}

/// A landed run of the slowest list. A click opens its page.
private struct SlowRunRow: View {
    let run: MetricsSlowRun
    let plotName: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: LoamTheme.space3) {
                Text(run.title).loamText(LoamTheme.rowStyle).lineLimit(1)
                if let plotName {
                    Text(plotName).loamText(LoamTheme.captionStyle, LoamColor.inkMuted).lineLimit(1)
                }
                Spacer(minLength: LoamTheme.space3)
                Text(MetricsWords.duration(run.leadSeconds)).loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).monospacedDigit()
            }
            .padding(.horizontal, LoamTheme.space4)
            .padding(.vertical, LoamTheme.space2)
            .contentShape(Rectangle())
            .background(hovered ? LoamColor.inkFill : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityIdentifier("metrics-slow-\(run.runID)")
    }
}
