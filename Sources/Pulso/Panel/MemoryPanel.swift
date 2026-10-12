import PulsoCore
import SwiftUI

struct MemoryPanel: View {
    let memory: MemorySnapshot
    let processes: ProcessSnapshot?
    let history: MetricHistory
    let hidden: Set<PanelSectionKind>
    let detail: PanelDetail

    @Environment(\.theme) private var theme

    private var isAdvanced: Bool { detail == .advanced }

    var body: some View {
        // Installed memory is a whole number of gigabytes; "16,0 GB" would suggest otherwise.
        let total = memory.total % (1 << 30) == 0 ? "\(memory.total >> 30) GB" : size(memory.total)
        PanelHeader(title: "Memoria", note: "\(size(memory.used)) de \(total) en uso",
                    figure: Format.percent(memory.usedFraction))

        let shares = [
            (name: "Memoria de apps", bytes: memory.app, color: theme.blue),
            (name: "Memoria reservada", bytes: memory.wired, color: theme.orange),
            (name: "Comprimida", bytes: memory.compressed, color: theme.aqua),
            (name: "Archivos en caché", bytes: memory.cached, color: theme.yellow),
            (name: "Libre", bytes: memory.free, color: theme.idle),
        ]

        if isAdvanced {
            VStack(spacing: 10) {
                breakdownGraph
                usageRange
            }
        } else {
            let used = history.values(\.memoryUsed)
            HistoryGraph(height: 48, timeline: history, traces: [
                GraphTrace(name: "Usada", color: theme.blue, fillOpacity: theme.singleAreaOpacity,
                           levels: used) { Format.percent(used[$0]) },
            ], topLabel: "100%", description: "Memoria usada reciente")
        }

        if !hidden.contains(.memoryBreakdown) {
            PanelSection(title: isAdvanced ? "Reparto ahora" : "Reparto", spacing: 8) {
                StackedBar(segments: shares.map { (Double($0.bytes), $0.color) })
                    .accessibilityHidden(true)
                if isAdvanced {
                    StatsTable(title: "De \(total)", columns: [("GB", 64), ("Parte", 56)], rows: shares.map {
                        StatsTable.Row(name: $0.name, swatch: $0.color, values: [
                            Format.number(Double($0.bytes) / Double(1 << 30), digits: 2),
                            Precise.percent(Double($0.bytes) / Double(max(1, memory.total))),
                        ])
                    }, dimsLastColumn: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(shares, id: \.name) { share in
                            ValueRow(share.name, size(share.bytes), swatch: share.color)
                        }
                    }
                }
            }
        }

        if !hidden.contains(.memoryStatus) {
            PanelSection(title: "Estado", spacing: 6) {
                HStack {
                    Text("Presión").foregroundStyle(theme.secondary)
                    Spacer()
                    StatusBadge(level: pressure)
                }
                .font(.panelRow)
                .frame(height: Metrics.rowHeight)
                .accessibilityElement(children: .combine)

                if memory.swapTotal > 0 {
                    let share = Double(memory.swapUsed) / Double(memory.swapTotal)
                    MeterRow(label: "Swap usado",
                             value: "\(size(memory.swapUsed)) de \(size(memory.swapTotal))"
                                 + (isAdvanced ? " · \(Precise.percent(share))" : ""),
                             fraction: share)
                } else {
                    ValueRow("Swap usado", "Sin swap")
                }
            }
        }

        if !hidden.contains(.memoryProcesses), let processes {
            PanelSection(title: "Procesos") {
                VStack(spacing: 0) {
                    ForEach(processes.topByMemory) { process in
                        ValueRow(process.name, Format.bytes(process.memory, binary: true))
                    }
                }
            }
        }
    }

    /// What the memory holds over time, one kind stacked on the other, against all that is installed.
    private var breakdownGraph: some View {
        let installed = Double(max(1, memory.total))
        let kinds: [(name: String, color: Color, values: [Double])] = [
            ("Memoria de apps", theme.blue, history.values(\.memoryApp)),
            ("Memoria reservada", theme.orange, history.values(\.memoryWired)),
            ("Comprimida", theme.aqua, history.values(\.memoryCompressed)),
            ("Archivos en caché", theme.yellow, history.values(\.memoryCached)),
        ]
        var below = Array(repeating: 0.0, count: history.samples.count)
        var traces: [GraphTrace] = []
        for kind in kinds {
            let above = zip(below, kind.values).map { $0 + $1 / installed }
            traces.append(GraphTrace(name: kind.name, color: kind.color, fillOpacity: theme.secondAreaOpacity,
                                     levels: above, base: below) { Format.bytes(UInt64(kind.values[$0]), binary: true) })
            below = above
        }
        let gigabytes = installed / Double(1 << 30)
        return HistoryGraph(height: 96, timeline: history, traces: traces, detail: HistoryGraph.Detail(
            marks: HistoryGraph.Detail.quarters { share in
                let amount = gigabytes * share
                return Format.number(amount, digits: amount == amount.rounded() ? 0 : 1) + (share == 1 ? " GB" : "")
            }, endDots: false), description: "Reparto reciente de la memoria: apps, reservada, comprimida y caché apiladas")
    }

    /// The lowest, mean and highest use over the window, side by side.
    private var usageRange: some View {
        let used = history.values(\.memoryUsed)
        let mean = used.isEmpty ? 0 : used.reduce(0, +) / Double(used.count)
        let cells = [("Uso mínimo", used.min() ?? 0), ("Uso medio", mean), ("Uso máximo", used.max() ?? 0)]
        return HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 1) {
                    Text(cells[index].0).font(.panelAxis).foregroundStyle(theme.muted).lineBox(12)
                    Text(Precise.percent(cells[index].1)).font(.panelRow).monospacedDigit().lineBox(15)
                }
                .padding(EdgeInsets(top: 6, leading: index == 0 ? 0 : 12, bottom: 7, trailing: 0))
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    if index > 0 { Rectangle().fill(theme.separator).frame(width: 1) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 1) }
    }

    private var pressure: Level {
        switch memory.pressure {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    private func size(_ bytes: UInt64) -> String {
        isAdvanced ? Precise.bytes(bytes, binary: true) : Format.bytes(bytes, binary: true)
    }
}

/// Parts of a whole side by side, set apart by 2 pt of panel showing through.
struct StackedBar: View {
    var segments: [(value: Double, color: Color)]

    var body: some View {
        let shown = segments.filter { $0.value > 0 }
        let total = shown.reduce(0) { $0 + $1.value }
        GeometryReader { proxy in
            let width = proxy.size.width - 2 * CGFloat(shown.count - 1)
            HStack(spacing: 2) {
                ForEach(shown.indices, id: \.self) { index in
                    UnevenRoundedRectangle(topLeadingRadius: index == 0 ? 4 : 0,
                                           bottomLeadingRadius: index == 0 ? 4 : 0,
                                           bottomTrailingRadius: index == shown.count - 1 ? 4 : 0,
                                           topTrailingRadius: index == shown.count - 1 ? 4 : 0)
                        .fill(shown[index].color)
                        .frame(width: max(0, width * shown[index].value / total))
                }
            }
        }
        .frame(height: 12)
    }
}
