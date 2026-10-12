import Foundation

/// The independent items Pulso can place in the menu bar.
enum ModuleKind: String, CaseIterable, Identifiable, Codable {
    case cpu, gpu, memory, disk, network, sensors, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memoria"
        case .disk: return "Disco"
        case .network: return "Red"
        case .sensors: return "Sensores"
        case .battery: return "Batería"
        }
    }

    /// Short tag drawn before the value in the menu bar. The network and battery items
    /// are recognisable without one.
    var shortLabel: String? {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .disk: return "SSD"
        case .sensors: return "TEMP"
        case .network, .battery: return nil
        }
    }
}
