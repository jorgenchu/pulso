import PulsoCore
import SwiftUI

struct CPUPanel: View {
    let snapshot: SystemSnapshot
    /// The load of the monitored cores; every CPU figure in the panel comes from it.
    let load: CPULoad
    let history: MetricHistory
    let hidden: Set<PanelSectionKind>
    let detail: PanelDetail

    @Environment(\.theme) private var theme

    var body: some View {
        let monitored = load.cores.count == load.coreCount ? "\(load.coreCount)" : "\(load.cores.count) de \(load.coreCount)"
        PanelHeader(title: "CPU", note: "\(SystemInfo.current.chip) · \(monitored) núcleos",
                    figure: Format.percent(load.usage))

        if detail == .advanced {
            VStack(spacing: 10) {
                Self.usageGraph(timeline: history, theme: theme, detailed: true)
                let user = history.values(\.cpuUser), system = history.values(\.cpuSystem)
                StatsTable.summary("Últimos \(HistoryGraph.duration(history.window))", [
                    ("Usuario", theme.blue, user), ("Sistema", theme.orange, system), ("Total", nil, zip(user, system).map(+)),
                ], format: Precise.percent)
            }
        } else {
            VStack(spacing: 6) {
                Self.usageGraph(timeline: history, theme: theme)
                VStack(spacing: 0) {
                    ValueRow("Usuario", Format.percent(load.user), swatch: theme.blue)
                    ValueRow("Sistema", Format.percent(load.system), swatch: theme.orange)
                    ValueRow("Inactivo", Format.percent(load.idle), swatch: .clear)
                }
            }
        }

        if !hidden.contains(.cpuCores) {
            if detail == .advanced {
                CoreHistories(load: load, history: history.last(CoreHistories.span))
            } else {
                PanelSection(title: "Núcleos", spacing: 8) {
                    CoreColumns(cores: load.cores)
                }
            }
        }

        if !hidden.contains(.cpuProcesses), let processes = snapshot.processes {
            PanelSection(title: "Procesos") {
                VStack(spacing: 0) {
                    ForEach(processes.topByCPU) { process in
                        ValueRow(process.name, Format.number(process.cpu, digits: 1) + "%")
                    }
                }
            }
        }

        if !hidden.contains(.cpuSystem) {
            PanelSection(title: "Sistema") {
                VStack(spacing: 0) {
                    ValueRow(detail == .advanced ? "Carga media · 1, 5 y 15 min" : "Carga media",
                             snapshot.cpu.loadAverage.map { Format.number($0, digits: 2) }.joined(separator: " · "))
                    ValueRow("Tiempo activo", Format.uptime(SystemInfo.current.uptime))
                }
            }
        }
    }

    /// User time stacked on top of system time, so the upper line is the total.
    static func usageGraph(timeline: MetricHistory, theme: Theme, detailed: Bool = false,
                           pinnedSample: Int? = nil) -> HistoryGraph {
        let user = timeline.values(\.cpuUser), system = timeline.values(\.cpuSystem)
        let total = zip(user, system).map(+)
        let percent = detailed ? Precise.percent : { Format.percent($0) }
        return HistoryGraph(height: detailed ? 96 : 64, timeline: timeline, traces: [
            GraphTrace(name: "Usuario", color: theme.blue, fillOpacity: theme.areaOpacity,
                       levels: total, base: system) { percent(user[$0]) },
            GraphTrace(name: "Sistema", color: theme.orange, fillOpacity: theme.secondAreaOpacity,
                       levels: system) { percent(system[$0]) },
        ], topLabel: "100%", detail: detailed ? HistoryGraph.Detail(
            marks: HistoryGraph.Detail.quarters { $0 == 1 ? "100%" : "\(Int($0 * 100))" },
            peak: (0, { Precise.percent(total[$0]) })) : nil,
        description: "Uso de CPU reciente, usuario y sistema apilados", pinnedSample: pinnedSample)
    }
}

/// The name a core goes by: its cluster's initial and its place in the cluster.
private func coreNames(_ cores: [CoreLoad]) -> [String] {
    var counters: [CoreKind: Int] = [:]
    return cores.map { core in
        counters[core.kind, default: 0] += 1
        return (core.kind == .efficiency ? "E" : "P") + "\(counters[core.kind] ?? 0)"
    }
}

/// One column per core, grouped by cluster.
private struct CoreColumns: View {
    var cores: [CoreLoad]

    @Environment(\.theme) private var theme

    private static let clusterSpacing: CGFloat = 14

    var body: some View {
        let clusters = [("Eficiencia", CoreKind.efficiency), ("Rendimiento", CoreKind.performance)]
            .map { title, kind in (title: title, cores: cores.filter { $0.kind == kind }) }
            .filter { !$0.cores.isEmpty }
        // Chips with many cores get narrower columns so that every cluster still fits.
        let available = Metrics.panelWidth - 2 * (Metrics.margin + 1) - Self.clusterSpacing * CGFloat(clusters.count - 1)
        let spacing: CGFloat = cores.count > 12 ? 3 : 6
        let width = min(Metrics.coreColumn.width,
                        ((available + spacing * CGFloat(clusters.count)) / CGFloat(max(1, cores.count)) - spacing).rounded(.down))

        HStack(alignment: .top, spacing: Self.clusterSpacing) {
            ForEach(clusters, id: \.title) { cluster in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(cluster.cores.indices, id: \.self) { index in
                            column(cluster.cores[index].usage).frame(width: width)
                        }
                    }
                    // Without two clusters to tell apart there is nothing to name.
                    if clusters.count > 1 {
                        Text(cluster.title).font(.panelAxis).foregroundStyle(theme.muted).fixedSize().lineBox(12)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(cluster.title)
                .accessibilityValue(cluster.cores.map { Format.percent($0.usage) }.joined(separator: ", "))
            }
        }
    }

    private func column(_ usage: Double) -> some View {
        let height = Metrics.coreColumn.height
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
        return shape.fill(theme.blue.opacity(theme.trackOpacity))
            .frame(height: height)
            .overlay(alignment: .bottom) {
                shape.fill(theme.blue).frame(height: max(2, (height * min(1, max(0, usage))).rounded()))
            }
    }
}

/// The recent load of each core as its own small graph, five to a row.
private struct CoreHistories: View {
    /// How far back each small graph looks, in seconds.
    static let span: TimeInterval = 40

    var load: CPULoad
    /// Already narrowed to `span`.
    var history: MetricHistory

    @Environment(\.theme) private var theme

    private static let perRow = 5

    var body: some View {
        let names = coreNames(load.cores)
        let clusters = Set(load.cores.map(\.kind)).count > 1 ? "E eficiencia · P rendimiento · " : ""
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Núcleos", note: "\(clusters)\(HistoryGraph.duration(Self.span))")
            VStack(spacing: 10) {
                ForEach(Array(stride(from: 0, to: load.cores.count, by: Self.perRow)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(start..<start + Self.perRow, id: \.self) { slot in
                            if slot < load.cores.count {
                                cell(names[slot], load.cores[slot].usage, core: load.indices[slot])
                            } else {
                                // Keeps a short last row on the same grid as the full ones.
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ name: String, _ usage: Double, core: Int) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(name).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(theme.muted)
                Spacer(minLength: 0)
                Text(Format.percent(usage)).font(.system(size: 10.5)).monospacedDigit()
            }
            .lineLimit(1)
            .lineBox(12)
            Sparkline(timeline: history, levels: history.values { core < $0.cores.count ? $0.cores[core] : 0 })
                .frame(height: 27)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(Format.percent(usage))
    }
}
