import Darwin
import Foundation

public enum CoreKind: String, Codable, Sendable {
    case performance, efficiency
}

public struct CPUTopology: Codable, Sendable, Equatable {
    public var logicalCores: Int
    public var performanceCores: Int
    public var efficiencyCores: Int

    public init(logicalCores: Int, performanceCores: Int, efficiencyCores: Int) {
        self.logicalCores = logicalCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
    }

    public static let current: CPUTopology = {
        let logical = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        guard (Sysctl.int("hw.nperflevels") ?? 1) >= 2,
              let performance = Sysctl.int("hw.perflevel0.logicalcpu"),
              let efficiency = Sysctl.int("hw.perflevel1.logicalcpu") else {
            return CPUTopology(logicalCores: logical, performanceCores: logical, efficiencyCores: 0)
        }
        return CPUTopology(logicalCores: logical, performanceCores: performance, efficiencyCores: efficiency)
    }()

    /// Apple Silicon enumerates the efficiency cluster before the performance ones.
    public func kind(ofCore index: Int) -> CoreKind {
        index < efficiencyCores ? .efficiency : .performance
    }
}

public struct CoreLoad: Codable, Sendable, Equatable {
    public var user: Double
    public var system: Double
    public var usage: Double
    public var kind: CoreKind
}

public struct CPUSnapshot: Codable, Sendable {
    /// Fractions of total CPU time, 0...1, averaged over every core.
    public var user: Double
    public var system: Double
    public var idle: Double
    public var usage: Double
    public var performanceUsage: Double?
    public var efficiencyUsage: Double?
    public var cores: [CoreLoad]
    /// 1, 5 and 15 minute load averages.
    public var loadAverage: [Double]
}

/// Cumulative scheduler ticks of one core.
struct CoreTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    /// Share of time spent in each state since `previous`. The counters wrap,
    /// so the differences are taken modulo 2³².
    func load(since previous: CoreTicks) -> (user: Double, system: Double, idle: Double) {
        let user = Double(self.user &- previous.user) + Double(self.nice &- previous.nice)
        let system = Double(self.system &- previous.system)
        let idle = Double(self.idle &- previous.idle)
        let total = user + system + idle
        guard total > 0 else { return (0, 0, 1) }
        return (user / total, system / total, idle / total)
    }
}

public final class CPUSampler {
    private let topology: CPUTopology
    private var previous: [CoreTicks]

    public init(topology: CPUTopology = .current) {
        self.topology = topology
        self.previous = Self.readTicks()
    }

    /// Load since the previous call (or since `init` for the first one).
    public func sample() -> CPUSnapshot {
        let current = Self.readTicks()
        defer { previous = current }
        return Self.snapshot(from: previous, to: current, topology: topology, loadAverage: Self.loadAverage())
    }

    static func snapshot(from previous: [CoreTicks], to current: [CoreTicks],
                         topology: CPUTopology, loadAverage: [Double]) -> CPUSnapshot {
        var cores: [CoreLoad] = []
        var user = 0.0, system = 0.0
        for (index, ticks) in current.enumerated() {
            let load = index < previous.count ? ticks.load(since: previous[index]) : (user: 0, system: 0, idle: 1)
            user += load.user
            system += load.system
            cores.append(CoreLoad(user: load.user, system: load.system,
                                  usage: min(1, load.user + load.system),
                                  kind: topology.kind(ofCore: index)))
        }
        let count = Double(max(1, cores.count))
        user /= count
        system /= count

        func average(_ kind: CoreKind) -> Double? {
            let matching = cores.filter { $0.kind == kind }
            guard !matching.isEmpty else { return nil }
            return matching.reduce(0) { $0 + $1.usage } / Double(matching.count)
        }
        return CPUSnapshot(user: user, system: system, idle: max(0, 1 - user - system),
                           usage: min(1, user + system),
                           performanceUsage: average(.performance),
                           efficiencyUsage: average(.efficiency),
                           cores: cores, loadAverage: loadAverage)
    }

    static func readTicks() -> [CoreTicks] {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(Mach.host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(coreCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            return CoreTicks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                             system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                             idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                             nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
    }

    static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return [] }
        return values
    }
}
