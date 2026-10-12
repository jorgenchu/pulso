import Combine
import Foundation
import PulsoCore
import ServiceManagement

/// User preferences, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    static let intervals: [TimeInterval] = [2, 3, 5, 10]
    static let defaultModules: Set<ModuleKind> = [.cpu, .memory, .network, .sensors]

    private enum Keys {
        static let modules = "enabledModules"
        static let interval = "refreshInterval"
        static let fahrenheit = "usesFahrenheit"
        static let detail = "panelDetail"
        static let graphStyle = "graphStyle"
        static let hiddenSections = "hiddenPanelSections"
        static let shownSections = "shownPanelSections"
        static let cpuGlyph = "cpuGlyph"
        static let ignoredCores = "ignoredCores"
        static let memoryValue = "memoryValue"
        static let memoryPill = "memoryShowsPill"
        static let diskValue = "diskValue"
        static let networkTraffic = "networkTraffic"
        static let sensorSource = "sensorSource"
        static let batteryValue = "batteryValue"
    }

    @Published var enabledModules: Set<ModuleKind> {
        didSet { defaults.set(enabledModules.map(\.rawValue).sorted(), forKey: Keys.modules) }
    }
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.interval) }
    }
    @Published var usesFahrenheit: Bool {
        didSet { defaults.set(usesFahrenheit, forKey: Keys.fahrenheit) }
    }
    @Published var detail: PanelDetail {
        didSet { defaults.set(detail.rawValue, forKey: Keys.detail) }
    }
    @Published var graphStyle: GraphStyle {
        didSet { defaults.set(graphStyle.rawValue, forKey: Keys.graphStyle) }
    }
    /// Panel sections the user switched off or on; the rest follow the default of the detail level.
    @Published private var hiddenByChoice: Set<PanelSectionKind> {
        didSet { defaults.set(hiddenByChoice.map(\.rawValue).sorted(), forKey: Keys.hiddenSections) }
    }
    @Published private var shownByChoice: Set<PanelSectionKind> {
        didSet { defaults.set(shownByChoice.map(\.rawValue).sorted(), forKey: Keys.shownSections) }
    }

    // What each menu bar item shows.
    @Published var cpuGlyph: CPUGlyph {
        didSet { defaults.set(cpuGlyph.rawValue, forKey: Keys.cpuGlyph) }
    }
    /// Cores left out of every CPU figure, by index. Never all of them.
    @Published private(set) var ignoredCores: Set<Int> {
        didSet { defaults.set(ignoredCores.sorted(), forKey: Keys.ignoredCores) }
    }
    @Published var memoryValue: MemoryValue {
        didSet { defaults.set(memoryValue.rawValue, forKey: Keys.memoryValue) }
    }
    @Published var memoryShowsPill: Bool {
        didSet { defaults.set(memoryShowsPill, forKey: Keys.memoryPill) }
    }
    @Published var diskValue: DiskValue {
        didSet { defaults.set(diskValue.rawValue, forKey: Keys.diskValue) }
    }
    @Published var networkTraffic: NetworkTraffic {
        didSet { defaults.set(networkTraffic.rawValue, forKey: Keys.networkTraffic) }
    }
    @Published var sensorSource: SensorSource {
        didSet { defaults.set(sensorSource.rawValue, forKey: Keys.sensorSource) }
    }
    @Published var batteryValue: BatteryValue {
        didSet { defaults.set(batteryValue.rawValue, forKey: Keys.batteryValue) }
    }

    /// Why the last attempt to change the login item failed, if it did.
    @Published private(set) var loginItemError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Keys.modules).map { Set($0.compactMap(ModuleKind.init(rawValue:))) }
        // With nothing in the menu bar there would be no way back into the app.
        enabledModules = stored.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultModules
        let interval = defaults.double(forKey: Keys.interval)
        refreshInterval = Self.intervals.contains(interval) ? interval : 3
        usesFahrenheit = defaults.bool(forKey: Keys.fahrenheit)

        func choice<Choice: SettingChoice>(_ key: String, default fallback: Choice) -> Choice {
            defaults.string(forKey: key).flatMap(Choice.init(rawValue:)) ?? fallback
        }
        detail = choice(Keys.detail, default: .simple)
        graphStyle = choice(Keys.graphStyle, default: .area)
        func sections(_ key: String) -> Set<PanelSectionKind> {
            Set((defaults.stringArray(forKey: key) ?? []).compactMap(PanelSectionKind.init(rawValue:)))
        }
        hiddenByChoice = sections(Keys.hiddenSections)
        shownByChoice = sections(Keys.shownSections)
        cpuGlyph = choice(Keys.cpuGlyph, default: .history)
        let coreCount = SystemInfo.current.topology.logicalCores
        let ignored = Set((defaults.array(forKey: Keys.ignoredCores) as? [Int] ?? []).filter { (0..<coreCount).contains($0) })
        ignoredCores = ignored.count < coreCount ? ignored : []
        memoryValue = choice(Keys.memoryValue, default: .percent)
        memoryShowsPill = defaults.object(forKey: Keys.memoryPill) == nil || defaults.bool(forKey: Keys.memoryPill)
        diskValue = choice(Keys.diskValue, default: .used)
        networkTraffic = choice(Keys.networkTraffic, default: .both)
        sensorSource = choice(Keys.sensorSource, default: .cpu)
        batteryValue = choice(Keys.batteryValue, default: .percent)
    }

    func isEnabled(_ kind: ModuleKind) -> Bool {
        enabledModules.contains(kind)
    }

    /// Turning off the last remaining module is refused.
    func setEnabled(_ enabled: Bool, for kind: ModuleKind) {
        if enabled {
            enabledModules.insert(kind)
        } else if enabledModules.count > 1 {
            enabledModules.remove(kind)
        }
    }

    func shows(_ section: PanelSectionKind) -> Bool {
        if section.isAdvancedOnly, detail == .simple { return false }
        if shownByChoice.contains(section) { return true }
        if hiddenByChoice.contains(section) { return false }
        return section.isShownByDefault(in: detail)
    }

    func setShown(_ shown: Bool, _ section: PanelSectionKind) {
        if shown {
            hiddenByChoice.remove(section)
            shownByChoice.insert(section)
        } else {
            shownByChoice.remove(section)
            hiddenByChoice.insert(section)
        }
    }

    /// Every section that is not on show.
    var hiddenSections: Set<PanelSectionKind> {
        Set(PanelSectionKind.allCases.filter { !shows($0) })
    }

    /// Whether the module's panel has a process list to fill.
    func listsProcesses(in kind: ModuleKind) -> Bool {
        PanelSectionKind.allCases.contains { $0.module == kind && $0.listsProcesses && shows($0) }
    }

    func monitors(core: Int) -> Bool {
        !ignoredCores.contains(core)
    }

    /// Leaving the last monitored core out is refused.
    func setMonitored(_ monitored: Bool, core: Int) {
        if monitored {
            ignoredCores.remove(core)
        } else if ignoredCores.count < SystemInfo.current.topology.logicalCores - 1 {
            ignoredCores.insert(core)
        }
    }

    /// What the module's menu bar item shows with the current options.
    func summary(for kind: ModuleKind) -> String {
        switch kind {
        case .cpu:
            switch cpuGlyph {
            case .history: return "Historial y uso"
            case .cores: return "Núcleos y uso"
            case .none: return "Uso"
            }
        case .gpu: return "Uso total"
        case .memory: return memoryValue == .percent ? "Memoria usada" : "Memoria en uso"
        case .disk: return diskValue == .used ? "Espacio ocupado" : "Espacio libre"
        case .network: return networkTraffic.title
        case .sensors:
            switch sensorSource {
            case .cpu: return "Temperatura de CPU"
            case .gpu: return "Temperatura de GPU"
            case .hottest: return "Sensor más caliente"
            }
        case .battery: return batteryValue == .percent ? "Carga" : "Tiempo restante"
        }
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
            }
        }
    }
}
