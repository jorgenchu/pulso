import Foundation
import IOKit

public struct GPUSnapshot: Codable, Sendable, Equatable {
    public var name: String
    /// 0...1, or nil when the driver does not publish it.
    public var utilization: Double?
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?
    public var memoryInUse: UInt64?
}

public struct GPUSampler {
    public init() {}

    public func sample() -> [GPUSnapshot] {
        var gpus: [GPUSnapshot] = []
        IORegistry.forEachService(matching: "IOAccelerator") { service in
            guard let statistics = IORegistry.property("PerformanceStatistics", of: service) as? [String: Any] else {
                return
            }
            gpus.append(Self.snapshot(name: Self.name(of: service) ?? "GPU", statistics: statistics))
        }
        return gpus
    }

    static func snapshot(name: String, statistics: [String: Any]) -> GPUSnapshot {
        func fraction(_ key: String) -> Double? {
            (statistics[key] as? NSNumber).map { min(1, max(0, $0.doubleValue / 100)) }
        }
        return GPUSnapshot(name: name,
                           utilization: fraction("Device Utilization %"),
                           rendererUtilization: fraction("Renderer Utilization %"),
                           tilerUtilization: fraction("Tiler Utilization %"),
                           memoryInUse: (statistics["In use system memory"] as? NSNumber)?.uint64Value)
    }

    /// `model` is a string on Apple Silicon and NUL-terminated data on Intel.
    private static func name(of service: io_service_t) -> String? {
        switch IORegistry.property("model", of: service) {
        case let text as String:
            return text
        case let data as Data:
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        default:
            return nil
        }
    }
}
