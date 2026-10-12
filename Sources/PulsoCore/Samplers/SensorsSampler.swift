import CPulso
import Foundation

public enum SensorGroup: String, Codable, Sendable, CaseIterable {
    case cpuPerformance, cpuEfficiency, cpu, gpu, soc, storage, battery, enclosure, other

    public var isCPU: Bool {
        self == .cpuPerformance || self == .cpuEfficiency || self == .cpu
    }
}

public struct TemperatureReading: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var celsius: Double
    public var group: SensorGroup

    public var id: String { name }
}

public struct FanReading: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var rpm: Double
    public var minimumRPM: Double
    public var maximumRPM: Double

    public var id: Int { index }

    /// Position between the fan's minimum and maximum speed, 0...1.
    public var fraction: Double {
        guard maximumRPM > minimumRPM else { return 0 }
        return min(1, max(0, (rpm - minimumRPM) / (maximumRPM - minimumRPM)))
    }
}

public struct PowerReading: Codable, Sendable, Equatable {
    /// Watts drawn by the whole machine.
    public var system: Double?
    /// Watts delivered by the power adapter; 0 on battery.
    public var adapter: Double?
}

public struct SensorsSnapshot: Codable, Sendable, Equatable {
    public var temperatures: [TemperatureReading]
    public var fans: [FanReading]
    public var power: PowerReading
    /// Mean of the CPU core sensors.
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    public var hottest: Double?

    public func temperatures(in group: SensorGroup) -> [TemperatureReading] {
        temperatures.filter { $0.group == group }
    }
}

public final class SensorsSampler {
    private let smc = SMCConnection()
    /// The SMC keys that turned out to exist on this machine. Resolved once.
    private lazy var smcSensors: [SMCSensor] = resolveSMCSensors()
    /// One entry per fan. How many there are and their speed range are fixed by the hardware.
    private lazy var fanLimits: [(minimum: Double, maximum: Double)] = resolveFanLimits()

    public init() {}

    public func sample() -> SensorsSnapshot {
        Self.snapshot(temperatures: readTemperatures(), fans: readFans(), power: readPower())
    }

    static func snapshot(temperatures: [TemperatureReading], fans: [FanReading], power: PowerReading) -> SensorsSnapshot {
        func mean(_ groups: SensorGroup...) -> Double? {
            let values = temperatures.filter { groups.contains($0.group) }.map(\.celsius)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return SensorsSnapshot(temperatures: temperatures, fans: fans, power: power,
                               cpuTemperature: mean(.cpuPerformance, .cpuEfficiency) ?? mean(.cpu),
                               gpuTemperature: mean(.gpu),
                               hottest: temperatures.map(\.celsius).max())
    }

    /// Unpopulated sensors read 0 or garbage.
    static func isPlausible(_ celsius: Double) -> Bool {
        celsius > 0 && celsius < 150
    }

    // MARK: Temperatures

    private func readTemperatures() -> [TemperatureReading] {
        let fromSMC: [TemperatureReading] = smcSensors.compactMap { sensor in
            guard let celsius = smc?.read(sensor.key)?.doubleValue, Self.isPlausible(celsius) else { return nil }
            return TemperatureReading(name: sensor.name, celsius: celsius, group: sensor.group)
        }
        return Self.merge(smc: fromSMC) { self.readHIDTemperatures() }
    }

    /// The SMC is the primary source. The HID sensors only fill in groups the SMC left
    /// empty, and are not read at all when the SMC already covers the CPU.
    static func merge(smc: [TemperatureReading], hid: () -> [TemperatureReading]) -> [TemperatureReading] {
        guard !smc.contains(where: { $0.group.isCPU }) else { return smc }
        let covered = Set(smc.map(\.group))
        return smc + hid().filter { !covered.contains($0.group) }
    }

    private func resolveSMCSensors() -> [SMCSensor] {
        guard let smc else { return [] }
        func existing(_ sensors: [SMCSensor]) -> [SMCSensor] {
            sensors.filter { smc.read($0.key)?.doubleValue.map(Self.isPlausible) ?? false }
        }
        var core = existing(SMCSensorCatalog.coreSensors(forChip: SystemInfo.current.chip))
        if !core.contains(where: { $0.group.isCPU }) {
            core = existing(SMCSensorCatalog.guessCoreSensors(among: smc.allKeys()))
        }
        return core + existing(SMCSensorCatalog.common)
    }

    private func readHIDTemperatures() -> [TemperatureReading] {
        // Vendor-defined usage page 0xFF00, usage 5: temperature sensors.
        let temperatureEvent: Int64 = 15
        var readings = [PulsoHIDReading](repeating: PulsoHIDReading(), count: 128)
        let count = Int(PulsoHIDReadSensors(0xFF00, 5, temperatureEvent, &readings, Int32(readings.count)))
        let named = readings.prefix(count).map { reading in
            (name: withUnsafeBytes(of: reading.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
             value: reading.value)
        }
        return Self.hidTemperatures(from: named)
    }

    static func hidTemperatures(from readings: [(name: String, value: Double)]) -> [TemperatureReading] {
        var seen: [String: Int] = [:]
        var result: [TemperatureReading] = []
        for (name, value) in readings.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            // `tcal` is a calibration constant, not a reading.
            guard isPlausible(value), !name.contains("tcal") else { continue }
            // Several services can share one product name.
            let occurrence = seen[name, default: 0] + 1
            seen[name] = occurrence
            result.append(TemperatureReading(name: occurrence == 1 ? name : "\(name) #\(occurrence)",
                                             celsius: value, group: hidGroup(forSensorNamed: name)))
        }
        return result
    }

    /// `PMU tdie`/`tdev` sit on the power management chip, not on the CPU cores, and
    /// run tens of degrees cooler than them under load, so they are not CPU sensors.
    static func hidGroup(forSensorNamed name: String) -> SensorGroup {
        let lowered = name.lowercased()
        if lowered.contains("pacc") { return .cpuPerformance }
        if lowered.contains("eacc") { return .cpuEfficiency }
        if lowered.contains("gpu") { return .gpu }
        if lowered.contains("soc") { return .soc }
        if lowered.contains("nand") || lowered.contains("ssd") { return .storage }
        if lowered.contains("battery") { return .battery }
        return .other
    }

    // MARK: Fans and power

    private func readFans() -> [FanReading] {
        guard let smc else { return [] }
        return fanLimits.enumerated().compactMap { index, limits in
            guard let rpm = smc.read("F\(index)Ac")?.doubleValue else { return nil }
            return FanReading(index: index, rpm: max(0, rpm), minimumRPM: limits.minimum, maximumRPM: limits.maximum)
        }
    }

    private func resolveFanLimits() -> [(minimum: Double, maximum: Double)] {
        guard let smc, let count = smc.read("FNum")?.doubleValue, count >= 1 else { return [] }
        return (0..<Int(count)).map { index in
            (smc.read("F\(index)Mn")?.doubleValue ?? 0, smc.read("F\(index)Mx")?.doubleValue ?? 0)
        }
    }

    private func readPower() -> PowerReading {
        func watts(_ key: String) -> Double? {
            guard let value = smc?.read(key)?.doubleValue, value.isFinite, value >= 0, value < 1000 else { return nil }
            // An unplugged adapter reads as float noise (~1e-5 W) rather than exactly zero.
            return value < 0.01 ? 0 : value
        }
        return PowerReading(system: watts("PSTR"), adapter: watts("PDTR"))
    }
}
