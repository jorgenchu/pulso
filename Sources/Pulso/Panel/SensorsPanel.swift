import PulsoCore
import SwiftUI

struct SensorsPanel: View {
    let sensors: SensorsSnapshot
    let history: MetricHistory
    let fahrenheit: Bool
    let hidden: Set<PanelSectionKind>
    let detail: PanelDetail
    @ObservedObject var fans: FanControlModel

    @Environment(\.theme) private var theme

    private var isAdvanced: Bool { detail == .advanced }

    private static let groups: [(title: String, group: SensorGroup)] = [
        ("CPU · rendimiento", .cpuPerformance), ("CPU · eficiencia", .cpuEfficiency), ("CPU", .cpu),
        ("GPU", .gpu), ("SoC", .soc), ("SSD", .storage), ("Batería", .battery),
        ("Carcasa", .enclosure), ("Otros", .other),
    ]

    var body: some View {
        PanelHeader(title: "Sensores", note: note,
                    figure: (sensors.cpuTemperature ?? sensors.hottest).map { Format.temperature($0, fahrenheit: fahrenheit) } ?? "—")

        // Only the samples that have a CPU reading can be drawn.
        let measured = history.filtered { $0.cpuTemperature != nil }
        if !measured.isEmpty {
            if isAdvanced {
                VStack(spacing: 10) {
                    temperatureGraph(measured)
                    let gpu = measured.samples.allSatisfy { $0.gpuTemperature != nil }
                    StatsTable.summary("\(fahrenheit ? "°F" : "°C") · últimos \(HistoryGraph.duration(history.window))",
                                       [("CPU", theme.blue, measured.values { $0.cpuTemperature ?? 0 })]
                                           + (gpu ? [("GPU", theme.orange, measured.values { $0.gpuTemperature ?? 0 })] : []),
                                       format: degrees)
                }
            } else {
                temperatureGraph(measured)
            }
        }

        // One row per group: its mean, and its hottest sensor when there are several.
        let rows = Self.groups.compactMap { title, group -> (title: String, group: SensorGroup, values: [Double])? in
            let values = sensors.temperatures(in: group).map(\.celsius)
            return values.isEmpty ? nil : (title, group, values)
        }
        if !hidden.contains(.sensorTemperatures), !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if isAdvanced {
                    SectionHeader(title: "Temperaturas", note: TemperatureScale.note(fahrenheit: fahrenheit))
                } else {
                    SectionTitle("Temperaturas")
                }
                ForEach(rows, id: \.title) { row in
                    let mean = row.values.reduce(0, +) / Double(row.values.count)
                    let hottest = row.values.max() ?? mean
                    MeterRow(label: row.title, detail: row.values.count > 1 ? "máx \(degrees(hottest))" : nil,
                             value: degrees(mean), fraction: TemperatureScale.fraction(mean),
                             level: TemperatureScale.level(of: hottest, in: row.group))
                }
            }
        }

        if !hidden.contains(.sensorFans), !sensors.fans.isEmpty {
            if isAdvanced {
                FanControls(readings: sensors.fans, model: fans)
            } else {
                PanelSection(title: "Ventiladores", spacing: 8) {
                    ForEach(sensors.fans) { fan in
                        FanReadingRow(fan: fan)
                    }
                }
            }
        }

        if !hidden.contains(.sensorPower), sensors.power.system != nil || (sensors.power.adapter ?? 0) > 0 {
            PanelSection(title: "Potencia") {
                VStack(spacing: 0) {
                    if let system = sensors.power.system {
                        ValueRow("Sistema", Format.number(system, digits: isAdvanced ? 2 : 1) + " W")
                    }
                    if let adapter = sensors.power.adapter, adapter > 0 {
                        ValueRow("Adaptador", Format.number(adapter, digits: isAdvanced ? 2 : 1) + " W")
                    }
                }
            }
        }
    }

    private func temperatureGraph(_ measured: MetricHistory) -> HistoryGraph {
        let cpu = measured.values { $0.cpuTemperature ?? 0 }
        let cpuTrace = GraphTrace(name: "CPU", color: theme.blue,
                                  fillOpacity: isAdvanced ? 0.12 : theme.singleAreaOpacity,
                                  levels: cpu.map(TemperatureScale.fraction)) { degrees(cpu[$0]) }
        guard isAdvanced else {
            return HistoryGraph(height: 56, timeline: measured, traces: [cpuTrace],
                                topLabel: Format.temperature(TemperatureScale.range.upperBound, fahrenheit: fahrenheit),
                                bottomLabel: Format.temperature(TemperatureScale.range.lowerBound, fahrenheit: fahrenheit),
                                description: "Temperatura reciente de la CPU")
        }
        var traces: [GraphTrace] = []
        if measured.samples.allSatisfy({ $0.gpuTemperature != nil }) {
            let gpu = measured.values { $0.gpuTemperature ?? 0 }
            traces.append(GraphTrace(name: "GPU", color: theme.orange, fillOpacity: 0,
                                     levels: gpu.map(TemperatureScale.fraction)) { degrees(gpu[$0]) })
        }
        traces.append(cpuTrace)
        let warning = TemperatureScale.warning
        return HistoryGraph(height: 96, timeline: measured, traces: traces, detail: HistoryGraph.Detail(
            marks: [110.0, 80, 50, 20].map {
                HistoryGraph.Detail.Mark(level: TemperatureScale.fraction($0),
                                         label: Format.temperature($0, fahrenheit: fahrenheit),
                                         isAxis: $0 == TemperatureScale.range.lowerBound)
            },
            threshold: (TemperatureScale.fraction(warning), "Aviso a \(Format.temperature(warning, fahrenheit: fahrenheit))")),
        description: "Temperatura reciente de la CPU y de la GPU")
    }

    private var note: String {
        guard sensors.cpuTemperature != nil else {
            return sensors.hottest == nil ? "No disponibles en este equipo" : "Sensor más caliente"
        }
        let count = sensors.temperatures.filter { $0.group.isCPU }.count
        // The sensors only map one to one to cores on some chips.
        return count == SystemInfo.current.topology.logicalCores
            ? "CPU · media de los \(count) núcleos" : "CPU · media de \(count) sensores"
    }

    private func degrees(_ celsius: Double) -> String {
        isAdvanced ? Precise.temperature(celsius, fahrenheit: fahrenheit) : Format.temperature(celsius, fahrenheit: fahrenheit)
    }
}

/// A fan's speed within its range.
private struct FanReadingRow: View {
    var fan: FanReading

    var body: some View {
        MeterRow(label: "Ventilador \(fan.index + 1)",
                 detail: "\(Format.number(fan.minimumRPM, digits: 0))–\(Format.number(fan.maximumRPM, digits: 0))",
                 value: Format.number(fan.rpm, digits: 0) + " rpm", fraction: fan.fraction)
    }
}

/// The fans with a switch between leaving them to the system and setting their speed.
private struct FanControls: View {
    var readings: [FanReading]
    @ObservedObject var model: FanControlModel

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Ventiladores")
                Spacer()
                // Without the helper there is nothing to switch; the note says how to get it.
                if model.isAvailable { modeSwitch }
            }
            if model.isManual {
                ForEach(model.fans) { fan in
                    FanSlider(fan: fan, rpm: readings.first { $0.index == fan.index }?.rpm ?? fan.rpm) {
                        model.setTarget($0, fan: fan.index)
                    }
                }
            } else {
                ForEach(readings) { fan in
                    FanReadingRow(fan: fan)
                }
            }
            if let note {
                Text(note).font(.panelDetail).foregroundStyle(theme.muted).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refresh() }
    }

    private var note: String? {
        if !model.isAvailable {
            // An app built with scripts/build-app.sh carries the installer; a bare `swift run` does not.
            let installer = Bundle.main.path(forResource: "install-fan-helper", ofType: "sh").map { "\"\($0)\"" }
                ?? "scripts/install-fan-helper.sh"
            return "Para fijar la velocidad a mano hace falta el servicio de ventiladores. Se instala una vez, desde Terminal, con: sudo \(installer)"
        }
        if let error = model.error {
            return error == .tooHot ? "La CPU está demasiado caliente para el control manual."
                : "El servicio de ventiladores no ha respondido."
        }
        return model.isManual
            ? "Vuelve a automático si la CPU pasa de \(Int(FanSupervisor.cutOffTemperature))° o al cerrar Pulso." : nil
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { manual in
                let isSelected = model.isManual == manual
                Button {
                    model.setManual(manual)
                } label: {
                    Text(manual ? "Manual" : "Automático")
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : theme.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Theme.selection : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.well))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ventiladores")
    }
}

/// The thumb is the speed asked for; the tick is the speed the fan has reached.
struct FanSlider: View {
    var fan: FanState
    /// The fan's speed right now.
    var rpm: Double
    var onChange: (Double) -> Void

    @Environment(\.theme) private var theme
    /// The speed under the pointer while the thumb is being dragged.
    @State private var dragged: Double?

    var body: some View {
        let limits = fan.limits
        let target = dragged ?? fan.targetRPM
        func share(_ speed: Double) -> CGFloat {
            limits.maximum > limits.minimum ? CGFloat(min(1, max(0, (speed - limits.minimum) / (limits.maximum - limits.minimum)))) : 0
        }
        return VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Ventilador \(fan.index + 1)").foregroundStyle(theme.secondary)
                Spacer(minLength: 4)
                Text("objetivo \(Format.number(target, digits: 0))").font(.panelDetail).monospacedDigit()
                    .foregroundStyle(theme.muted)
                Text(Format.number(rpm, digits: 0) + " rpm").monospacedDigit()
            }
            .font(.panelRow)
            .lineLimit(1)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.blue.opacity(theme.trackOpacity)).frame(height: 4)
                    Capsule().fill(theme.blue).frame(width: width * share(target), height: 4)
                    RoundedRectangle(cornerRadius: 1).fill(theme.muted).frame(width: 2, height: 12)
                        .offset(x: width * share(rpm) - 1)
                    Circle().fill(Theme.dark.text).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                        .offset(x: width * share(target) - 8)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let speed = limits.minimum + Double(min(1, max(0, value.location.x / width))) * (limits.maximum - limits.minimum)
                        // Steps of 50 rpm: finer than a fan can hold anyway.
                        dragged = limits.clamp((speed / 50).rounded() * 50)
                    }
                    .onEnded { _ in
                        if let dragged { onChange(dragged) }
                        dragged = nil
                    })
            }
            .frame(height: 16)
            .accessibilityElement()
            .accessibilityLabel("Velocidad objetivo del ventilador \(fan.index + 1), en revoluciones por minuto")
            .accessibilityValue(Format.number(target, digits: 0))
            .accessibilityAdjustableAction { direction in
                onChange(limits.clamp(target + (direction == .increment ? 100 : -100)))
            }
            HStack {
                Text("\(Format.number(limits.minimum, digits: 0)) mín")
                Spacer()
                Text("\(Format.number(limits.maximum, digits: 0)) máx")
            }
            .font(.panelAxis)
            .monospacedDigit()
            .lineBox(12)
            .foregroundStyle(theme.muted)
        }
    }
}

/// The one scale every temperature meter and graph is drawn on, and where a reading
/// stops being normal.
enum TemperatureScale {
    /// In °C.
    static let range: ClosedRange<Double> = 20...110
    /// Where silicon starts to deserve attention, in °C.
    static let warning = 90.0

    static func fraction(_ celsius: Double) -> Double {
        (celsius - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// "Escala de 20° a 110°".
    static func note(fahrenheit: Bool) -> String {
        "Escala de \(Format.temperature(range.lowerBound, fahrenheit: fahrenheit)) a \(Format.temperature(range.upperBound, fahrenheit: fahrenheit))"
    }

    /// Silicon throttles near 100 °C; a battery stops charging at 45 °C and an SSD
    /// starts throttling around 70 °C.
    static func level(of celsius: Double, in group: SensorGroup) -> Level {
        let limits: (warning: Double, critical: Double)
        switch group {
        case .battery: limits = (40, 45)
        case .storage: limits = (70, 80)
        default: limits = (warning, 100)
        }
        return celsius >= limits.critical ? .critical : celsius >= limits.warning ? .warning : .normal
    }
}
