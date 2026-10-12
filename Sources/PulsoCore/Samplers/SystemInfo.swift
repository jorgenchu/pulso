import Darwin
import Foundation

/// Facts about the machine that do not change while it is running.
public struct SystemInfo: Codable, Sendable, Equatable {
    public var model: String
    public var chip: String
    public var osVersion: String
    public var topology: CPUTopology
    public var memory: UInt64
    public var bootTime: Date

    public var uptime: TimeInterval { Date().timeIntervalSince(bootTime) }

    public static let current: SystemInfo = {
        let boot = Sysctl.value("kern.boottime", as: timeval.self)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemInfo(model: Sysctl.string("hw.model") ?? "Mac",
                          chip: Sysctl.string("machdep.cpu.brand_string") ?? "",
                          osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                          topology: .current,
                          memory: ProcessInfo.processInfo.physicalMemory,
                          bootTime: boot.map { Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_usec) / 1e6) }
                              ?? Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime))
    }()
}
