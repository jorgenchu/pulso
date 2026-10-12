import PulsoCore
import SwiftUI

/// The dropdown shown under a status item: the module's own view on the panel surface.
struct ModulePanel: View {
    let kind: ModuleKind
    @ObservedObject var store: MetricsStore
    @ObservedObject var settings: AppSettings
    var fans: FanControlModel
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            if let snapshot = store.snapshot {
                content(snapshot)
            } else {
                PanelHeader(title: kind.title, note: "Midiendo…", figure: "—")
            }
            PanelFooter(onOpenSettings: onOpenSettings, onQuit: onQuit)
        }
        // The 1 pt edge lies outside the margin.
        .padding(Metrics.margin + 1)
        .frame(width: Metrics.panelWidth, alignment: .leading)
        .foregroundStyle(theme.text)
        .background(shape.fill(theme.panel))
        .overlay(shape.strokeBorder(theme.outline))
        .environment(\.graphStyle, settings.graphStyle)
    }

    @ViewBuilder
    private func content(_ snapshot: SystemSnapshot) -> some View {
        switch kind {
        case .cpu:
            CPUPanel(snapshot: snapshot, load: CPULoad(snapshot.cpu, ignoring: settings.ignoredCores),
                     history: store.history, hidden: settings.hiddenSections, detail: settings.detail)
        case .gpu:
            if let gpu = snapshot.gpus.first, let utilization = gpu.utilization {
                GPUPanel(gpu: gpu, utilization: utilization, sensors: snapshot.sensors, peaks: store.temperaturePeaks,
                         history: store.history, fahrenheit: settings.usesFahrenheit, detail: settings.detail)
            } else {
                unavailable
            }
        case .memory:
            if let memory = snapshot.memory {
                MemoryPanel(memory: memory, processes: snapshot.processes, history: store.history,
                            hidden: settings.hiddenSections, detail: settings.detail)
            } else {
                unavailable
            }
        case .disk:
            DiskPanel(disk: snapshot.disk, history: store.history, hidden: settings.hiddenSections,
                      detail: settings.detail)
        case .network:
            NetworkPanel(network: snapshot.network, processes: snapshot.networkProcesses, history: store.history,
                         hidden: settings.hiddenSections, detail: settings.detail)
        case .sensors:
            SensorsPanel(sensors: snapshot.sensors, history: store.history, fahrenheit: settings.usesFahrenheit,
                         hidden: settings.hiddenSections, detail: settings.detail, fans: fans)
        case .battery:
            if let battery = snapshot.battery {
                BatteryPanel(battery: battery, fahrenheit: settings.usesFahrenheit, hidden: settings.hiddenSections)
            } else {
                unavailable
            }
        }
    }

    private var unavailable: some View {
        PanelHeader(title: kind.title, note: "No disponible en este equipo", figure: "—")
    }
}
