import PulsoCore
import SwiftUI

struct SettingsView: View {
    static let width: CGFloat = 520

    /// The general settings, or the options of one module.
    enum Page: Hashable {
        case general
        case module(ModuleKind)

        var title: String {
            switch self {
            case .general: return "General"
            case let .module(kind): return kind.title
            }
        }
    }

    @ObservedObject var settings: AppSettings
    /// Modules this machine cannot show, e.g. the battery on a desktop.
    var unavailableModules: Set<ModuleKind>

    @Environment(\.theme) private var theme
    @State private var page: Page

    init(settings: AppSettings, unavailableModules: Set<ModuleKind> = [], page: Page = .general) {
        self.settings = settings
        self.unavailableModules = unavailableModules
        _page = State(initialValue: page)
    }

    /// The pages this machine has something to set on. The GPU has no options of its own.
    func pages() -> [Page] {
        [.general] + ModuleKind.allCases.filter { $0 != .gpu && !unavailableModules.contains($0) }.map(Page.module)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SegmentedControl(options: pages().map { ($0, $0.title) }, selection: $page)
                .accessibilityLabel("Sección")
            // Every page is laid out and only the chosen one shown, so the window keeps
            // the height of the tallest page instead of jumping between them.
            ZStack(alignment: .top) {
                ForEach(pages(), id: \.self) { candidate in
                    VStack(alignment: .leading, spacing: 20) { content(of: candidate) }
                        .opacity(candidate == page ? 1 : 0)
                        .disabled(candidate != page)
                        .accessibilityHidden(candidate != page)
                }
            }
        }
        .toggleStyle(SwitchStyle())
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20))
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(theme.text)
        .background(theme.panel)
        // The rule under the title bar, which shares the surface of the content.
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
    }

    @ViewBuilder
    private func content(of page: Page) -> some View {
        switch page {
        case .general: general
        case .module(.cpu): cpu
        case .module(.gpu): EmptyView()
        case .module(.memory): memory
        case .module(.disk): disk
        case .module(.network): network
        case .module(.sensors): sensors
        case .module(.battery): battery
        }
    }

    // MARK: Pages

    @ViewBuilder
    private var general: some View {
        section("Barra de menús") {
            ForEach(ModuleKind.allCases) { kind in
                row(first: kind == ModuleKind.allCases.first) {
                    Toggle(isOn: Binding(get: { settings.isEnabled(kind) },
                                         set: { settings.setEnabled($0, for: kind) })) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(kind.title).font(.settingsRow)
                            Text(settings.summary(for: kind)).font(.panelNote).foregroundStyle(theme.muted)
                        }
                    }
                    // The last module left on cannot be switched off.
                    .disabled(unavailableModules.contains(kind)
                        || (settings.isEnabled(kind) && settings.enabledModules.count == 1))
                }
            }
        } footnote: {
            Text("Arrastra los elementos con ⌘ para reordenarlos en la barra.")
        }

        section("Paneles") {
            choice("Detalle", $settings.detail, width: 94, first: true)
            choice("Gráficas", $settings.graphStyle, width: 62)
        } footnote: {
            Text("Avanzado añade ejes y tablas a las gráficas, el historial de cada núcleo, el tráfico de red por proceso y el control de los ventiladores. Solo consume más mientras un panel está abierto.")
        }

        section("General") {
            choice("Actualizar la barra cada", AppSettings.intervals.map { ($0, "\(Int($0)) s") },
                   $settings.refreshInterval, width: 46, first: true)
            choice("Temperatura", [(false, "Celsius"), (true, "Fahrenheit")], $settings.usesFahrenheit, width: 94)
            row {
                Toggle(isOn: Binding(get: { settings.launchesAtLogin }, set: { settings.launchesAtLogin = $0 })) {
                    Text("Abrir al iniciar sesión").font(.settingsRow)
                }
            }
        } footnote: {
            Text("Con un panel abierto, sus datos se actualizan cada segundo. Pulso deja de medir con la pantalla apagada o bloqueada.")
            if let error = settings.loginItemError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusIcon(level: .critical)
                    Text(error)
                }
            }
        }
    }

    @ViewBuilder
    private var cpu: some View {
        section("Barra de menús") {
            choice("Gráfica", $settings.cpuGlyph, width: 84, first: true)
        }
        section("Núcleos que monitorizar") {
            row(first: true, height: nil) {
                CorePicker(settings: settings).padding(.vertical, 12)
                Spacer(minLength: 0)
            }
        } footnote: {
            Text("El uso, el historial y las columnas del panel cuentan solo los núcleos elegidos.")
        }
        panelSections(of: .cpu)
    }

    @ViewBuilder
    private var memory: some View {
        section("Barra de menús") {
            choice("Valor", $settings.memoryValue, width: 84, first: true)
            row {
                Toggle(isOn: $settings.memoryShowsPill) {
                    Text("Píldora de uso").font(.settingsRow)
                }
            }
        }
        panelSections(of: .memory)
    }

    @ViewBuilder
    private var disk: some View {
        section("Barra de menús") {
            choice("Valor", $settings.diskValue, width: 84, first: true)
        }
        panelSections(of: .disk)
    }

    @ViewBuilder
    private var network: some View {
        section("Barra de menús") {
            choice("Tráfico", $settings.networkTraffic, width: 112, first: true)
        }
        panelSections(of: .network)
    }

    @ViewBuilder
    private var sensors: some View {
        section("Barra de menús") {
            choice("Sensor", $settings.sensorSource, width: 94, first: true)
        }
        panelSections(of: .sensors)
    }

    @ViewBuilder
    private var battery: some View {
        section("Barra de menús") {
            choice("Valor", $settings.batteryValue, width: 84, first: true)
        } footnote: {
            Text("El tiempo se muestra mientras la batería se carga o se descarga.")
        }
        panelSections(of: .battery)
    }

    // MARK: Building blocks

    /// A heading, a card of rows and an optional note under it.
    private func section(_ title: String, @ViewBuilder rows: () -> some View,
                         @ViewBuilder footnote: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title).padding(.horizontal, 2)
            VStack(spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.group))
            VStack(alignment: .leading, spacing: 6) { footnote() }
                .font(.panelNote).lineSpacing(2).foregroundStyle(theme.muted).padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A row of the standard height, or as tall as its content when `height` is nil.
    private func row(first: Bool = false, height: CGFloat? = 44, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.horizontal, 14)
            .frame(height: height)
            .overlay(alignment: .top) {
                if !first { Rectangle().fill(theme.separator).frame(height: 1) }
            }
    }

    /// A row that picks one of a few options.
    private func choice<Value: Hashable>(_ title: String, _ options: [(Value, String)], _ selection: Binding<Value>,
                                         width: CGFloat, first: Bool = false) -> some View {
        row(first: first) {
            Text(title).font(.settingsRow)
            Spacer()
            SegmentedControl(options: options, selection: selection, segmentWidth: width)
                .accessibilityLabel(title)
        }
    }

    private func choice<Value: SettingChoice>(_ title: String, _ selection: Binding<Value>, width: CGFloat,
                                              first: Bool = false) -> some View {
        choice(title, Value.allCases.map { ($0, $0.title) }, selection, width: width, first: first)
    }

    /// One switch per section of the module's panel.
    private func panelSections(of kind: ModuleKind) -> some View {
        // Sections that only the advanced panels have are listed while those are in use.
        let sections = PanelSectionKind.allCases.filter {
            $0.module == kind && (settings.detail == .advanced || !$0.isAdvancedOnly)
        }
        return section("Secciones del panel") {
            ForEach(sections) { part in
                row(first: part == sections.first) {
                    Toggle(isOn: Binding(get: { settings.shows(part) }, set: { settings.setShown($0, part) })) {
                        Text(part.title).font(.settingsRow)
                    }
                }
            }
        }
    }
}

/// One chip per core, grouped by cluster. A chip that is on is a core Pulso monitors.
private struct CorePicker: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.theme) private var theme

    var body: some View {
        let topology = SystemInfo.current.topology
        let clusters = [("Eficiencia", CoreKind.efficiency), ("Rendimiento", CoreKind.performance)]
            .map { title, kind in
                (title: title, cores: (0..<topology.logicalCores).filter { topology.kind(ofCore: $0) == kind })
            }
            .filter { !$0.cores.isEmpty }
        // Machines with many cores get narrower chips so that they still fit the row.
        let width: CGFloat = topology.logicalCores > 12 ? 16 : 28

        HStack(alignment: .top, spacing: 14) {
            ForEach(clusters, id: \.title) { cluster in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        ForEach(cluster.cores, id: \.self) { core in
                            chip(core: core, number: core - cluster.cores[0] + 1, cluster: cluster.title, width: width)
                        }
                    }
                    if clusters.count > 1 {
                        Text(cluster.title).font(.panelAxis).foregroundStyle(theme.muted).lineBox(12)
                    }
                }
            }
        }
    }

    private func chip(core: Int, number: Int, cluster: String, width: CGFloat) -> some View {
        let isOn = settings.monitors(core: core)
        return Button {
            settings.setMonitored(!isOn, core: core)
        } label: {
            Text("\(number)")
                .font(.system(size: width < 28 ? 10 : 12.5, weight: isOn ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isOn ? .white : theme.secondary)
                .frame(width: width, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Theme.selection : theme.well))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Núcleo \(number) de \(cluster.lowercased())")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A switch drawn in the panel's own colours. The whole row toggles it.
private struct SwitchStyle: ToggleStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                Capsule().fill(configuration.isOn ? theme.blue : theme.axis)
                    .frame(width: 38, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                    }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "activado" : "desactivado")
    }
}

/// A row of mutually exclusive options; the chosen one is filled.
private struct SegmentedControl<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value
    /// Without a width, the segments share the room there is.
    var segmentWidth: CGFloat?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let isSelected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : theme.secondary)
                        .frame(width: segmentWidth, height: 26)
                        .frame(maxWidth: segmentWidth == nil ? .infinity : nil)
                        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Theme.selection : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.well))
        .accessibilityElement(children: .contain)
    }
}
