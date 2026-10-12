import Darwin
import Foundation
import IOKit

// Fan control has three parts, split by who may do what:
//
//   FanControlClient  the app, unprivileged: asks the helper over a Unix socket.
//   FanSupervisor     the rules: what is allowed and when to hand the fans back. No hardware.
//   SMCFanController  the hardware: writes the SMC. Only works as root, so only the helper uses it.
//
// The helper (`pulso-fand`) is the only root process. It trusts nothing it is sent: every
// speed is clamped to the fan's own range, and it returns the fans to the system on its own
// if the app goes quiet, the CPU gets hot, or it is told to stop.

public enum FanMode: String, Codable, Sendable {
    case automatic, manual
}

public struct FanLimits: Codable, Sendable, Equatable {
    public var minimum: Double
    public var maximum: Double

    public init(minimum: Double, maximum: Double) {
        self.minimum = minimum
        self.maximum = maximum
    }

    /// The nearest speed the fan can actually be asked for.
    public func clamp(_ rpm: Double) -> Double {
        min(max(rpm, minimum), max(minimum, maximum))
    }
}

public struct FanState: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var mode: FanMode
    public var rpm: Double
    public var targetRPM: Double
    public var limits: FanLimits

    public var id: Int { index }
}

public enum FanControlError: String, Error, Codable, Sendable {
    /// The helper is not installed or not running.
    case helperUnavailable
    case noSuchFan
    case missingSpeed
    /// Manual control is refused while the CPU is above the cut-off temperature.
    case tooHot
    case notPrivileged
    case writeFailed
    case badRequest
}

public struct FanRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        /// Reports the fans. Also counts as contact, like `ping`.
        case status
        /// Sets one fan to a fixed speed.
        case set
        /// Returns one fan, or all of them when `fan` is nil, to the system.
        case automatic
        /// Tells the helper the app is still there. Needed at least every
        /// `FanSupervisor.contactTimeout` seconds while any fan is manual.
        case ping
    }

    public var command: Command
    public var fan: Int?
    public var rpm: Double?

    public init(command: Command, fan: Int? = nil, rpm: Double? = nil) {
        self.command = command
        self.fan = fan
        self.rpm = rpm
    }
}

public struct FanResponse: Codable, Sendable, Equatable {
    public var error: FanControlError?
    public var fans: [FanState]

    public init(error: FanControlError? = nil, fans: [FanState]) {
        self.error = error
        self.fans = fans
    }
}

/// Decides what the helper does with each request and on each tick. Pure logic.
public struct FanSupervisor {
    public enum Action: Equatable {
        case set(fan: Int, rpm: Double)
        case automatic(fan: Int)
        case restoreAll
    }

    /// Without contact for this long, manual fans go back to the system: the app
    /// crashed, was force-quit, or the Mac slept with a low speed still pinned.
    public static let contactTimeout: TimeInterval = 30
    /// Manual control ends at this CPU temperature and is refused until it drops to `resumeTemperature`.
    public static let cutOffTemperature = 95.0
    public static let resumeTemperature = 85.0

    /// The speed asked of each fan that is held in manual.
    public private(set) var targets: [Int: Double] = [:]
    public private(set) var isLockedOut = false
    private var lastContact: TimeInterval = 0

    public init() {}

    public var manualFans: Set<Int> {
        Set(targets.keys)
    }

    /// Whether `tick` needs calling: only while something is being held away from the system.
    public var needsWatching: Bool {
        !targets.isEmpty || isLockedOut
    }

    /// The fans as they read once the SMC has taken in everything asked of it. It applies a
    /// write a moment after accepting it, so a reading taken straight after `actions` still
    /// shows the old mode and target; this fills in what was asked. Measured speeds are left alone.
    public func settled(_ fans: [FanState], after actions: [Action] = []) -> [FanState] {
        fans.map { fan in
            var fan = fan
            if let target = targets[fan.index] {
                fan.mode = .manual
                fan.targetRPM = target
            } else if actions.contains(.restoreAll) || actions.contains(.automatic(fan: fan.index)) {
                fan.mode = .automatic
            }
            return fan
        }
    }

    public mutating func handle(_ request: FanRequest, limits: [FanLimits],
                                now: TimeInterval) -> Result<[Action], FanControlError> {
        lastContact = now
        switch request.command {
        case .status, .ping:
            return .success([])
        case .automatic:
            guard let fan = request.fan else {
                targets.removeAll()
                return .success([.restoreAll])
            }
            guard limits.indices.contains(fan) else { return .failure(.noSuchFan) }
            targets[fan] = nil
            return .success([.automatic(fan: fan)])
        case .set:
            guard let fan = request.fan, limits.indices.contains(fan) else { return .failure(.noSuchFan) }
            guard let rpm = request.rpm, rpm.isFinite else { return .failure(.missingSpeed) }
            guard !isLockedOut else { return .failure(.tooHot) }
            let speed = limits[fan].clamp(rpm)
            targets[fan] = speed
            return .success([.set(fan: fan, rpm: speed)])
        }
    }

    public mutating func tick(now: TimeInterval, cpuTemperature: Double?) -> [Action] {
        if let cpuTemperature {
            if cpuTemperature >= Self.cutOffTemperature, !isLockedOut {
                isLockedOut = true
                targets.removeAll()
                return [.restoreAll]
            }
            if cpuTemperature < Self.resumeTemperature { isLockedOut = false }
        }
        if !targets.isEmpty, now - lastContact > Self.contactTimeout {
            targets.removeAll()
            return [.restoreAll]
        }
        return []
    }
}

/// Reads and sets the fans through the SMC. Setting needs root.
public final class SMCFanController {
    private let smc: SMCConnection
    public let limits: [FanLimits]

    public init?() {
        guard let smc = SMCConnection(), let count = smc.read("FNum")?.doubleValue, count >= 1 else { return nil }
        self.smc = smc
        limits = (0..<Int(count)).map { fan in
            FanLimits(minimum: smc.read("F\(fan)Mn")?.doubleValue ?? 0, maximum: smc.read("F\(fan)Mx")?.doubleValue ?? 0)
        }
    }

    public func states() -> [FanState] {
        limits.enumerated().map { fan, limits in
            FanState(index: fan,
                     mode: smc.read("F\(fan)Md")?.doubleValue == 1 ? .manual : .automatic,
                     rpm: max(0, smc.read("F\(fan)Ac")?.doubleValue ?? 0),
                     targetRPM: smc.read("F\(fan)Tg")?.doubleValue ?? 0,
                     limits: limits)
        }
    }

    public func perform(_ action: FanSupervisor.Action) throws {
        switch action {
        case let .set(fan, rpm):
            // Some chips gate manual control behind this switch; where it is absent the write is skipped.
            if smc.read("Ftst") != nil { try write("Ftst", [1]) }
            try write("F\(fan)Md", [1])
            try write("F\(fan)Tg", Self.encode(rpm: Float(limits[fan].clamp(rpm))))
        case let .automatic(fan):
            try write("F\(fan)Md", [0])
        case .restoreAll:
            var failure: Error?
            for fan in limits.indices {
                do { try write("F\(fan)Md", [0]) } catch { failure = error }
            }
            if smc.read("Ftst") != nil { try? write("Ftst", [0]) }
            if let failure { throw failure }
        }
    }

    /// The SMC stores fan speeds as little-endian 32-bit floats.
    static func encode(rpm: Float) -> [UInt8] {
        withUnsafeBytes(of: rpm.bitPattern.littleEndian, Array.init)
    }

    private func write(_ key: String, _ bytes: [UInt8]) throws {
        let result = smc.write(key, bytes: bytes)
        guard result != KERN_SUCCESS else { return }
        throw result == kIOReturnNotPrivileged ? FanControlError.notPrivileged : FanControlError.writeFailed
    }
}

/// Talks to the helper. One short connection per request.
public struct FanControlClient: Sendable {
    public static let defaultSocketPath = "/var/run/pulso-fand.sock"

    public var socketPath: String

    public init(socketPath: String = FanControlClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    /// Whether the helper's socket exists. Cheap enough to decide if the controls are shown.
    public var isHelperAvailable: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    public func send(_ request: FanRequest) throws -> FanResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FanControlError.helperUnavailable }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard var address = UnixSocket.address(for: socketPath) else { throw FanControlError.helperUnavailable }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw FanControlError.helperUnavailable }

        guard let payload = try? JSONEncoder().encode(request), UnixSocket.write(payload + [0x0A], to: descriptor),
              let line = UnixSocket.readLine(from: descriptor),
              let response = try? JSONDecoder().decode(FanResponse.self, from: line) else {
            throw FanControlError.badRequest
        }
        return response
    }
}

/// The few socket chores shared by the client and the helper.
public enum UnixSocket {
    public static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        return address
    }

    public static func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress! + sent, buffer.count - sent)
                guard result > 0 else { return false }
                sent += result
            }
            return true
        }
    }

    /// Reads up to the first newline, or nil if none arrives within `limit` bytes.
    public static func readLine(from descriptor: Int32, limit: Int = 8192) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < limit {
            guard read(descriptor, &byte, 1) == 1 else { return line.isEmpty ? nil : line }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return nil
    }
}
