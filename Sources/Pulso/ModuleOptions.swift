import Foundation
import PulsoCore

/// A setting with a fixed set of choices, shown as a segmented control.
protocol SettingChoice: RawRepresentable, CaseIterable, Hashable where RawValue == String {
    var title: String { get }
}

/// What the CPU item draws next to its value.
enum CPUGlyph: String, SettingChoice {
    case history, cores, none

    var title: String {
        switch self {
        case .history: return "Historial"
        case .cores: return "Por núcleo"
        case .none: return "Ninguna"
        }
    }
}

enum MemoryValue: String, SettingChoice {
    case percent, used

    var title: String {
        self == .percent ? "Porcentaje" : "En uso"
    }
}

enum DiskValue: String, SettingChoice {
    case used, free

    var title: String {
        self == .used ? "Ocupado" : "Libre"
    }
}

enum NetworkTraffic: String, SettingChoice {
    case both, download, upload

    var title: String {
        switch self {
        case .both: return "Subida y bajada"
        case .download: return "Bajada"
        case .upload: return "Subida"
        }
    }
}

/// Which temperature the sensors item shows.
enum SensorSource: String, SettingChoice {
    case cpu, gpu, hottest

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .hottest: return "Más caliente"
        }
    }
}

enum BatteryValue: String, SettingChoice {
    case percent, time

    var title: String {
        self == .percent ? "Carga" : "Tiempo"
    }
}

/// How much the panels show. Advanced adds scales and tables to the graphs, the history of
/// each core, traffic per process and fan control.
enum PanelDetail: String, SettingChoice {
    case simple, advanced

    var title: String {
        self == .simple ? "Simple" : "Avanzado"
    }
}

/// How the history graphs in the panels are drawn.
enum GraphStyle: String, SettingChoice {
    case area, line, bars

    var title: String {
        switch self {
        case .area: return "Área"
        case .line: return "Línea"
        case .bars: return "Barras"
        }
    }
}

/// A part of a panel that can be hidden.
enum PanelSectionKind: String, CaseIterable, Identifiable {
    case cpuCores, cpuProcesses, cpuSystem
    case memoryBreakdown, memoryStatus, memoryProcesses
    case diskVolumes, diskActivity, diskTotals
    case networkProcesses, networkSession, networkInterface, networkOtherInterfaces
    case sensorTemperatures, sensorFans, sensorPower
    case batteryHealth

    var id: String { rawValue }

    var module: ModuleKind {
        switch self {
        case .cpuCores, .cpuProcesses, .cpuSystem: return .cpu
        case .memoryBreakdown, .memoryStatus, .memoryProcesses: return .memory
        case .diskVolumes, .diskActivity, .diskTotals: return .disk
        case .networkProcesses, .networkSession, .networkInterface, .networkOtherInterfaces: return .network
        case .sensorTemperatures, .sensorFans, .sensorPower: return .sensors
        case .batteryHealth: return .battery
        }
    }

    /// The heading the section has in its panel.
    var title: String {
        switch self {
        case .cpuCores: return "Núcleos"
        case .cpuProcesses, .memoryProcesses, .networkProcesses: return "Procesos"
        case .cpuSystem: return "Sistema"
        case .memoryBreakdown: return "Reparto"
        case .memoryStatus: return "Estado"
        case .diskVolumes: return "Volúmenes"
        case .diskActivity: return "Actividad"
        case .diskTotals: return "Desde el arranque"
        case .networkSession: return "Esta sesión"
        case .networkInterface: return "Conexión principal"
        case .networkOtherInterfaces: return "Otras interfaces"
        case .sensorTemperatures: return "Temperaturas"
        case .sensorFans: return "Ventiladores"
        case .sensorPower: return "Potencia"
        case .batteryHealth: return "Salud"
        }
    }

    /// Sections that only the advanced panels have.
    var isAdvancedOnly: Bool {
        self == .networkProcesses
    }

    /// The sections that are extra detail start out hidden.
    func isShownByDefault(in detail: PanelDetail) -> Bool {
        switch self {
        case .networkOtherInterfaces: return false
        case .diskTotals, .networkProcesses: return detail == .advanced
        default: return true
        }
    }

    /// Listing processes costs a `ps` run per sample.
    var listsProcesses: Bool {
        self == .cpuProcesses || self == .memoryProcesses
    }
}

/// The CPU load over the cores Pulso is set to monitor.
struct CPULoad {
    let cores: [CoreLoad]
    /// Where each of `cores` sits among all the machine's cores.
    let indices: [Int]
    /// Fractions of the monitored cores' time, 0...1.
    let user: Double
    let system: Double
    /// How many cores the machine has, monitored or not.
    let coreCount: Int

    var usage: Double { min(1, user + system) }
    var idle: Double { max(0, 1 - user - system) }

    init(_ cpu: CPUSnapshot, ignoring ignored: Set<Int>) {
        coreCount = cpu.cores.count
        let kept = cpu.cores.indices.filter { !ignored.contains($0) }
        guard !kept.isEmpty, kept.count < cpu.cores.count else {
            cores = cpu.cores
            indices = Array(cpu.cores.indices)
            user = cpu.user
            system = cpu.system
            return
        }
        let monitored = kept.map { cpu.cores[$0] }
        cores = monitored
        indices = kept
        user = monitored.reduce(0) { $0 + $1.user } / Double(monitored.count)
        system = monitored.reduce(0) { $0 + $1.system } / Double(monitored.count)
    }
}
