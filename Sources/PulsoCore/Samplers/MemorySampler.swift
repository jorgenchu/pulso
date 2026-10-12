import Darwin
import Foundation

public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical
}

public struct MemorySnapshot: Codable, Sendable, Equatable {
    public var total: UInt64
    /// App + wired + compressed, which is what Activity Monitor calls "Memory Used".
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure
    public var usedFraction: Double
}

/// The page counters the breakdown is derived from.
struct MemoryPages: Equatable {
    var `internal`: UInt64
    var purgeable: UInt64
    var wired: UInt64
    var compressor: UInt64
    var external: UInt64
}

public struct MemorySampler {
    private let total: UInt64
    private let pageSize: UInt64

    public init() {
        total = ProcessInfo.processInfo.physicalMemory
        var size: vm_size_t = 0
        host_page_size(Mach.host, &size)
        pageSize = size > 0 ? UInt64(size) : 16_384
    }

    public func sample() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Mach.host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pages = MemoryPages(internal: UInt64(stats.internal_page_count),
                                purgeable: UInt64(stats.purgeable_count),
                                wired: UInt64(stats.wire_count),
                                compressor: UInt64(stats.compressor_page_count),
                                external: UInt64(stats.external_page_count))
        let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self)
        return Self.snapshot(pages: pages, pageSize: pageSize, total: total,
                             swapUsed: swap?.xsu_used ?? 0, swapTotal: swap?.xsu_total ?? 0,
                             pressure: Self.pressure())
    }

    /// Same accounting as Activity Monitor: purgeable pages count as cache, not app memory.
    static func snapshot(pages: MemoryPages, pageSize: UInt64, total: UInt64,
                         swapUsed: UInt64, swapTotal: UInt64, pressure: MemoryPressure) -> MemorySnapshot {
        let app = (pages.internal > pages.purgeable ? pages.internal - pages.purgeable : 0) * pageSize
        let wired = pages.wired * pageSize
        let compressed = pages.compressor * pageSize
        let used = min(total, app + wired + compressed)
        let cached = min(total - used, (pages.external + pages.purgeable) * pageSize)
        return MemorySnapshot(total: total, used: used, app: app, wired: wired, compressed: compressed,
                              cached: cached, free: total - used - cached,
                              swapUsed: swapUsed, swapTotal: swapTotal, pressure: pressure,
                              usedFraction: total > 0 ? Double(used) / Double(total) : 0)
    }

    static func pressure() -> MemoryPressure {
        switch Sysctl.int("kern.memorystatus_vm_pressure_level") {
        case 2: return .warning
        case 4: return .critical
        default: return .normal
        }
    }
}
