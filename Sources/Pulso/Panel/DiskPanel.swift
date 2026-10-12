import PulsoCore
import SwiftUI

struct DiskPanel: View {
    let disk: DiskSnapshot
    let history: MetricHistory
    let hidden: Set<PanelSectionKind>
    let detail: PanelDetail

    @Environment(\.theme) private var theme

    private var isAdvanced: Bool { detail == .advanced }

    var body: some View {
        if let root = disk.root {
            PanelHeader(title: "Disco", note: "\(size(root.available)) libres de \(size(root.total))",
                        figure: Format.percent(root.usedFraction))
        } else {
            PanelHeader(title: "Disco", note: "Sin volumen de arranque", figure: "—")
        }

        if !hidden.contains(.diskVolumes), !disk.volumes.isEmpty {
            PanelSection(title: "Volúmenes", spacing: 10) {
                ForEach(disk.volumes) { volume in
                    VolumeRow(volume: volume, isAdvanced: isAdvanced)
                }
            }
        }

        if !hidden.contains(.diskActivity) {
            let read = history.values(\.diskRead), write = history.values(\.diskWrite)
            let scale = RateScale(peak: max(read.max() ?? 0, write.max() ?? 0), minimum: 1_000_000)
            PanelSection(title: "Actividad", spacing: isAdvanced ? 10 : 6) {
                HistoryGraph.mirrored(timeline: history, upper: ("Lectura", read), lower: ("Escritura", write),
                                      scale: scale, detailed: isAdvanced, simpleHeight: 72, theme: theme,
                                      description: "Actividad de disco reciente: lectura hacia arriba, escritura hacia abajo")
                if isAdvanced {
                    StatsTable.summary("\(scale.unit) · últimos \(HistoryGraph.duration(history.window))", [
                        ("Lectura", theme.blue, read), ("Escritura", theme.orange, write),
                    ], format: scale.text)
                } else {
                    VStack(spacing: 0) {
                        ValueRow("Lectura", Format.rate(disk.activity.readRate), swatch: theme.blue)
                        ValueRow("Escritura", Format.rate(disk.activity.writeRate), swatch: theme.orange)
                    }
                }
            }
        }

        if !hidden.contains(.diskTotals) {
            PanelSection(title: "Desde el arranque") {
                VStack(spacing: 0) {
                    ValueRow("Leído", size(disk.activity.totalRead))
                    ValueRow("Escrito", size(disk.activity.totalWritten))
                }
            }
        }
    }

    private func size(_ bytes: UInt64) -> String {
        isAdvanced ? Precise.bytes(bytes) : Format.bytes(bytes)
    }
}

private struct VolumeRow: View {
    var volume: VolumeInfo
    var isAdvanced: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: isAdvanced ? 5 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(volume.name).font(.panelRow).lineLimit(1).layoutPriority(1)
                Text(kind).font(.panelDetail).foregroundStyle(theme.muted).lineLimit(1)
                Spacer(minLength: 6)
                Text(isAdvanced ? Precise.percent(volume.usedFraction) : "\(Format.bytes(volume.available)) libres")
                    .font(.panelRow).monospacedDigit().lineLimit(1).layoutPriority(2)
            }
            Meter(fraction: volume.usedFraction, height: 6)
            if isAdvanced {
                HStack {
                    Text("\(Precise.bytes(volume.used)) usados")
                    Spacer(minLength: 6)
                    Text("\(Precise.bytes(volume.available)) libres de \(Precise.bytes(volume.total))")
                }
                .font(.panelDetail)
                .monospacedDigit()
                .lineLimit(1)
                .lineBox(13)
                .foregroundStyle(theme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Where the volume lives and its file system: "Interno · APFS".
    private var kind: String {
        let place = volume.isNetwork ? "Red" : volume.isInternal ? "Interno" : "Externo"
        return [place, volume.format].compactMap { $0 }.joined(separator: " · ")
    }
}
