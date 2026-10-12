import Foundation
import IOKit

public struct BatterySnapshot: Codable, Sendable, Equatable {
    /// 0...1.
    public var charge: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    /// Minutes until empty (on battery) or until full (while charging); nil while the system is still estimating.
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// Current full-charge capacity relative to the design capacity, 0...1.
    public var health: Double?
    public var designCapacity: Int?
    public var maximumCapacity: Int?
    /// Celsius. The battery stopped publishing this itself in recent macOS releases;
    /// `SystemMonitor` fills it in from the SMC battery sensors when it is missing.
    public var temperature: Double?
    public var voltage: Double?
    /// Amps; negative while discharging.
    public var amperage: Double?
    /// Watts flowing into (positive) or out of (negative) the battery.
    public var power: Double?
    public var adapterWatts: Int?
    public var adapterName: String?
}

public struct BatterySampler {
    public init() {}

    /// Returns nil on Macs without a battery.
    public func sample() -> BatterySnapshot? {
        var snapshot: BatterySnapshot?
        IORegistry.forEachService(matching: "AppleSmartBattery") { service in
            guard snapshot == nil, let properties = IORegistry.properties(of: service) else { return }
            snapshot = Self.snapshot(properties: properties)
        }
        return snapshot
    }

    static func snapshot(properties: [String: Any]) -> BatterySnapshot? {
        // Newer macOS releases moved the capacity figures from the top level into `BatteryData`.
        let nested = properties["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { ((properties[key] ?? nested[key]) as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { (properties[key] as? NSNumber)?.boolValue ?? false }

        guard (properties["BatteryInstalled"] as? NSNumber)?.boolValue ?? true,
              let current = int("CurrentCapacity"), let maximum = int("MaxCapacity"), maximum > 0 else { return nil }

        let isCharging = bool("IsCharging")
        let isPluggedIn = bool("ExternalConnected")

        // 65535 is the gauge's "still calculating" marker.
        var minutesRemaining: Int?
        if let minutes = int("TimeRemaining"), minutes > 0, minutes < 65_535, isCharging || !isPluggedIn {
            minutesRemaining = minutes
        }

        let design = int("DesignCapacity")
        let rawMaximum = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        var health: Double?
        if let design, design > 0, let rawMaximum {
            health = min(1, Double(rawMaximum) / Double(design))
        }

        // The registry stores amperage as an unsigned 64-bit two's complement value.
        let voltage = int("Voltage").map { Double($0) / 1000 }
        let amperage = (properties["Amperage"] as? NSNumber).map { Double($0.int64Value) / 1000 }
        let adapter = properties["AdapterDetails"] as? [String: Any]

        return BatterySnapshot(charge: min(1, Double(current) / Double(maximum)),
                               isCharging: isCharging,
                               isPluggedIn: isPluggedIn,
                               isFullyCharged: bool("FullyCharged"),
                               minutesRemaining: minutesRemaining,
                               cycleCount: int("CycleCount"),
                               health: health,
                               designCapacity: design,
                               maximumCapacity: rawMaximum,
                               temperature: int("Temperature").map { Double($0) / 100 },
                               voltage: voltage,
                               amperage: amperage,
                               power: voltage.flatMap { volts in amperage.map { volts * $0 } },
                               adapterWatts: (adapter?["Watts"] as? NSNumber)?.intValue,
                               adapterName: adapter?["Name"] as? String)
    }
}
