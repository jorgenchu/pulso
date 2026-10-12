import Foundation

struct SMCSensor: Equatable {
    var key: String
    var name: String
    var group: SensorGroup
}

/// Which SMC keys hold which temperature. Apple does not document these and they
/// change with every chip generation; the per-family tables come from community
/// reverse engineering and only the M1 one has been checked against real hardware.
enum SMCSensorCatalog {
    /// The "M<n>" generation in a brand string such as "Apple M1 Pro", or nil on Intel.
    static func generation(ofChip chip: String) -> Int? {
        guard let range = chip.range(of: #"\bM\d+"#, options: .regularExpression) else { return nil }
        return Int(chip[range].dropFirst())
    }

    /// Per-core CPU and GPU sensors for a chip, or nothing when the generation is unknown.
    static func coreSensors(forChip chip: String) -> [SMCSensor] {
        let keys: (efficiency: [String], performance: [String], gpu: [String])
        switch generation(ofChip: chip) {
        case 1:
            keys = (["Tp09", "Tp0T"],
                    ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
                    ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        case 2:
            keys = (["Tp1h", "Tp1t", "Tp1p", "Tp1l"],
                    ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
                    ["Tg0f", "Tg0j"])
        case 3:
            keys = (["Te05", "Te0L", "Te0P", "Te0S"],
                    ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                    ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
        case 4:
            keys = (["Te05", "Te0S", "Te09", "Te0H"],
                    ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
                    ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        default:
            return []
        }
        func numbered(_ keys: [String], _ prefix: String, _ group: SensorGroup) -> [SMCSensor] {
            keys.enumerated().map { SMCSensor(key: $1, name: "\(prefix)\($0 + 1)", group: group) }
        }
        return numbered(keys.performance, "CPU P", .cpuPerformance)
            + numbered(keys.efficiency, "CPU E", .cpuEfficiency)
            + numbered(keys.gpu, "GPU ", .gpu)
    }

    /// Sensors whose keys have stayed stable across generations.
    static let common: [SMCSensor] = [
        SMCSensor(key: "TH0x", name: "SSD", group: .storage),
        SMCSensor(key: "TB0T", name: "Battery 1", group: .battery),
        SMCSensor(key: "TB1T", name: "Battery 2", group: .battery),
        SMCSensor(key: "TB2T", name: "Battery 3", group: .battery),
        SMCSensor(key: "Ts0P", name: "Palm rest 1", group: .enclosure),
        SMCSensor(key: "Ts1P", name: "Palm rest 2", group: .enclosure),
        SMCSensor(key: "TaLP", name: "Airflow left", group: .enclosure),
        SMCSensor(key: "TaRF", name: "Airflow right", group: .enclosure),
        SMCSensor(key: "TW0P", name: "Wi-Fi", group: .other),
    ]

    /// Last resort for a chip with no table: go by the key prefixes Apple has used so far.
    /// Coarser than a table (it cannot tell core kinds apart, and it picks up filtered
    /// variants of the same sensor), but the resulting average is still representative.
    static func guessCoreSensors(among keys: [String]) -> [SMCSensor] {
        keys.compactMap { key in
            if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tf") {
                return SMCSensor(key: key, name: key, group: .cpu)
            }
            if key.hasPrefix("Tg") {
                return SMCSensor(key: key, name: key, group: .gpu)
            }
            return nil
        }
    }
}
