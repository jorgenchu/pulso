import PulsoCore
import SwiftUI

struct GPUPanel: View {
    let gpu: GPUSnapshot
    let utilization: Double
    let sensors: SensorsSnapshot
    /// The highest reading of each sensor since Pulso started, by sensor name.
    let peaks: [String: Double]
    let history: MetricHistory
    let fahrenheit: Bool
    let detail: PanelDetail

    @Environment(\.theme) private var theme

    var body: some View {
        if detail == .advanced {
            advanced
        } else {
            simple
        }
    }

    @ViewBuilder
    private var simple: some View {
        PanelHeader(title: "GPU", note: gpu.name, figure: Format.percent(utilization))

        let usage = history.values(\.gpu)
        HistoryGraph(height: 64, timeline: history, traces: [
            GraphTrace(name: "Uso", color: theme.blue, fillOpacity: theme.singleAreaOpacity,
                       levels: usage) { Format.percent(usage[$0]) },
        ], topLabel: "100%", description: "Uso reciente de la GPU")

        if gpu.memoryInUse != nil || sensors.gpuTemperature != nil {
            VStack(spacing: 6) {
                if let memory = gpu.memoryInUse {
                    ValueRow("Memoria en uso", Format.bytes(memory, binary: true))
                }
                if let temperature = sensors.gpuTemperature {
                    MeterRow(label: "Temperatura", value: Format.temperature(temperature, fahrenheit: fahrenheit),
                             fraction: TemperatureScale.fraction(temperature),
                             level: TemperatureScale.level(of: temperature, in: .gpu))
                }
            }
        }
    }

    @ViewBuilder
    private var advanced: some View {
        PanelHeader(title: "GPU", note: "\(gpu.name) · uso total", figure: Format.percent(utilization))

        let total = history.values(\.gpu)
        // The GPU reports how busy its two stages are; the total is the busier one.
        let stages = gpu.rendererUtilization != nil && gpu.tilerUtilization != nil
        let render = history.values { $0.gpuRender ?? 0 }, geometry = history.values { $0.gpuGeometry ?? 0 }
        VStack(spacing: 10) {
            HistoryGraph(height: 96, timeline: history, traces: stages ? [
                GraphTrace(name: "Total", color: theme.blue, fillOpacity: 0.12, levels: total, isLine: false) {
                    Precise.percent(total[$0])
                },
                GraphTrace(name: "Geometría", color: theme.orange, fillOpacity: 0, levels: geometry) {
                    Precise.percent(geometry[$0])
                },
                GraphTrace(name: "Render", color: theme.blue, fillOpacity: 0, levels: render) { Precise.percent(render[$0]) },
            ] : [
                GraphTrace(name: "Uso", color: theme.blue, fillOpacity: 0.12, levels: total) { Precise.percent(total[$0]) },
            ], detail: HistoryGraph.Detail(marks: HistoryGraph.Detail.quarters { $0 == 1 ? "100%" : "\(Int($0 * 100))" },
                                          peak: (0, { Precise.percent(total[$0]) })),
            description: "Uso reciente de la GPU: total, render y geometría")
            StatsTable.summary("Últimos \(HistoryGraph.duration(history.window))", stages ? [
                ("Render", theme.blue, render), ("Geometría", theme.orange, geometry), ("Total", nil, total),
            ] : [("Uso", theme.blue, total)], format: Precise.percent)
        }

        if let memory = gpu.memoryInUse {
            PanelSection(title: "Memoria") {
                let recent = history.last(60)
                let used = recent.values(\.gpuMemory)
                // Scaled to its own range, with headroom: the shape matters here, not the height.
                let ceiling = max(1, (used.max() ?? 0) * 1.25)
                HStack(spacing: 10) {
                    Text("En uso").foregroundStyle(theme.secondary)
                    Spacer(minLength: 0)
                    Sparkline(timeline: recent, levels: used.map { $0 / ceiling }).frame(width: 96, height: 17)
                    Text(Format.bytes(memory, binary: true)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                }
                .font(.panelRow)
                .frame(height: Metrics.rowHeight)
            }
        }

        let readings = sensors.temperatures(in: .gpu)
        if !readings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Temperatura", note: TemperatureScale.note(fahrenheit: fahrenheit))
                ForEach(readings) { reading in
                    MeterRow(label: reading.name,
                             detail: "máx \(Precise.temperature(peaks[reading.name] ?? reading.celsius, fahrenheit: fahrenheit))",
                             value: Precise.temperature(reading.celsius, fahrenheit: fahrenheit),
                             fraction: TemperatureScale.fraction(reading.celsius),
                             level: TemperatureScale.level(of: reading.celsius, in: .gpu))
                }
            }
        }
    }
}
