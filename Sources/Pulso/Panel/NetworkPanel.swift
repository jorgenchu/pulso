import PulsoCore
import SwiftUI

struct NetworkPanel: View {
    let network: NetworkSnapshot
    /// Traffic per process; arrives a few seconds after its list comes on screen.
    let processes: NetworkProcessSnapshot?
    let history: MetricHistory
    let hidden: Set<PanelSectionKind>
    let detail: PanelDetail

    @Environment(\.theme) private var theme

    private var isAdvanced: Bool { detail == .advanced }

    var body: some View {
        // "1,80 MB/s" split into the figure and its unit.
        let rate = Format.rate(network.downloadRate).split(separator: " ")
        PanelHeader(title: "Red", note: network.primary.map { "\($0.displayName) · bajada" } ?? "Sin conexión",
                    figure: String(rate[0]), unit: String(rate[1]))

        let download = history.values(\.download), upload = history.values(\.upload)
        let scale = RateScale(peak: max(download.max() ?? 0, upload.max() ?? 0), minimum: 100_000)
        VStack(spacing: isAdvanced ? 10 : 6) {
            HistoryGraph.mirrored(timeline: history, upper: ("Bajada", download), lower: ("Subida", upload),
                                  scale: scale, detailed: isAdvanced, simpleHeight: 80, theme: theme,
                                  description: "Tráfico de red reciente: bajada hacia arriba, subida hacia abajo")
            if isAdvanced {
                StatsTable.summary("\(scale.unit) · últimos \(HistoryGraph.duration(history.window))", [
                    ("Bajada", theme.blue, download), ("Subida", theme.orange, upload),
                ], format: scale.text)
            } else {
                VStack(spacing: 0) {
                    ValueRow("Bajada", Format.rate(network.downloadRate), swatch: theme.blue)
                    ValueRow("Subida", Format.rate(network.uploadRate), swatch: theme.orange)
                }
            }
        }

        if !hidden.contains(.networkProcesses) {
            PanelSection(title: "Procesos") {
                ProcessTrafficList(processes: processes)
            }
        }

        if !hidden.contains(.networkSession) {
            PanelSection(title: "Esta sesión") {
                VStack(spacing: 0) {
                    ValueRow("Descargado", Format.bytes(network.sessionDownloaded))
                    ValueRow("Enviado", Format.bytes(network.sessionUploaded))
                }
            }
        }

        let interfaces = network.interfaces.filter { !hidden.contains($0.isPrimary ? .networkInterface : .networkOtherInterfaces) }
        ForEach(interfaces) { interface in
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(interface.displayName)
                    Spacer()
                    // The advanced panel names the interface here instead of in a row of its own.
                    let role = [interface.isPrimary ? "Conexión principal" : nil, isAdvanced ? interface.name : nil]
                        .compactMap { $0 }.joined(separator: " · ")
                    Text(role).font(.panelDetail).foregroundStyle(theme.muted)
                }
                VStack(spacing: 0) {
                    if !isAdvanced {
                        ValueRow("Interfaz", interface.name)
                    }
                    ForEach(interface.addresses, id: \.self) { address in
                        ValueRow(address.contains(":") ? "IPv6" : "IPv4", address, truncatesValue: true)
                    }
                }
            }
        }
    }
}

/// The processes moving the most data, each with a pair of bars on one shared scale so
/// that their lengths compare across rows.
private struct ProcessTrafficList: View {
    var processes: NetworkProcessSnapshot?

    @Environment(\.theme) private var theme

    private static let rateWidth: CGFloat = 74

    var body: some View {
        let rows = (processes?.top ?? []).map { (name: $0.name, down: $0.downloadRate, up: $0.uploadRate, isRest: false) }
            + (processes.map { $0.otherCount > 0
                    ? [(name: "Otros \($0.otherCount) procesos", down: $0.otherDownloadRate, up: $0.otherUploadRate, isRest: true)]
                    : [] } ?? [])
        let widest = max(1, rows.map { $0.down + $0.up }.max() ?? 0)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Por tráfico total")
                Spacer(minLength: 4)
                Text("Bajada").frame(width: Self.rateWidth, alignment: .trailing)
                Text("Subida").frame(width: Self.rateWidth, alignment: .trailing)
            }
            .font(.panelAxis)
            .foregroundStyle(theme.muted)
            .frame(height: 16)

            if rows.isEmpty {
                Text(processes == nil ? "Midiendo…" : "Sin tráfico")
                    .font(.panelRow).foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
            }
            ForEach(rows, id: \.name) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(row.name).foregroundStyle(row.isRest ? theme.muted : theme.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.rate(row.down)).monospacedDigit().frame(width: Self.rateWidth, alignment: .trailing)
                        Text(Format.rate(row.up)).monospacedDigit().frame(width: Self.rateWidth, alignment: .trailing)
                    }
                    .font(.panelRow)
                    .lineBox(16)
                    GeometryReader { proxy in
                        HStack(spacing: 2) {
                            Capsule().fill(theme.blue).frame(width: max(2, (proxy.size.width - 2) * row.down / widest))
                            Capsule().fill(theme.orange).frame(width: max(2, (proxy.size.width - 2) * row.up / widest))
                        }
                    }
                    .frame(height: 3)
                    .accessibilityHidden(true)
                }
                // 1 pt of rule, then the row's own padding.
                .padding(.top, 5)
                .padding(.bottom, 5)
                .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
