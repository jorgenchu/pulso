import CPulso
import Darwin
import Foundation
import SystemConfiguration

public struct InterfaceSnapshot: Codable, Sendable, Equatable, Identifiable {
    /// BSD name, e.g. `en0`.
    public var name: String
    /// User-facing name, e.g. "Wi-Fi".
    public var displayName: String
    public var isPrimary: Bool
    public var addresses: [String]
    /// Bytes per second.
    public var downloadRate: Double
    public var uploadRate: Double
    /// Cumulative bytes since the interface came up.
    public var totalDownloaded: UInt64
    public var totalUploaded: UInt64

    public var id: String { name }
}

public struct NetworkSnapshot: Codable, Sendable, Equatable {
    /// Bytes per second summed over the hardware interfaces.
    public var downloadRate: Double
    public var uploadRate: Double
    /// Bytes moved since the sampler started.
    public var sessionDownloaded: UInt64
    public var sessionUploaded: UInt64
    public var primaryInterface: String?
    /// Interfaces that currently hold an address, primary first.
    public var interfaces: [InterfaceSnapshot]

    public var primary: InterfaceSnapshot? { interfaces.first { $0.isPrimary } }
}

struct InterfaceCounters: Equatable {
    var received: UInt64
    var sent: UInt64

    /// Bytes moved since `previous`. A counter that went backwards means the
    /// interface was reset, so that interval counts as zero.
    func delta(since previous: InterfaceCounters) -> (received: UInt64, sent: UInt64) {
        (received >= previous.received ? received - previous.received : 0,
         sent >= previous.sent ? sent - previous.sent : 0)
    }
}

/// Things that rarely change and are comparatively expensive to look up.
struct InterfaceMetadata {
    var displayNames: [String: String] = [:]
    var addresses: [String: [String]] = [:]
    var primary: String?
}

/// Tells whether the network configuration changed since it was last asked, by
/// subscribing to the system configuration store instead of polling it.
final class NetworkChangeObserver {
    /// Shared with the store's callback, which can outlive the observer by a moment.
    private final class Flag {
        private let lock = NSLock()
        private var isSet = true

        func set() {
            lock.withLock { isSet = true }
        }

        func consume() -> Bool {
            lock.withLock {
                defer { isSet = false }
                return isSet
            }
        }
    }

    private let flag = Flag()
    private let queue = DispatchQueue(label: "pulso.network-changes", qos: .utility)
    private var store: SCDynamicStore?

    init() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(flag).toOpaque(),
            retain: { UnsafeRawPointer(Unmanaged<Flag>.fromOpaque($0).retain().toOpaque()) },
            release: { Unmanaged<Flag>.fromOpaque($0).release() },
            copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<Flag>.fromOpaque(info).takeUnretainedValue().set()
        }
        guard let store = SCDynamicStoreCreate(nil, "Pulso" as CFString, callback, &context) else { return }
        // Routing changes (which interface is primary) and per-interface address or link changes.
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Interface"]
        let patterns = ["State:/Network/Interface/[^/]+/(IPv4|IPv6|Link)"]
        guard SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray),
              SCDynamicStoreSetDispatchQueue(store, queue) else { return }
        self.store = store
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }

    /// False when the subscription could not be set up, in which case callers must poll.
    var isWatching: Bool { store != nil }

    /// True once after every change (and the first time it is asked).
    func consumeChange() -> Bool {
        flag.consume()
    }

    func primaryInterface() -> String? {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return nil
        }
        return global["PrimaryInterface"] as? String
    }
}

public final class NetworkSampler {
    private var previous: [String: InterfaceCounters]
    private var previousTime: TimeInterval
    private var sessionDownloaded: UInt64 = 0
    private var sessionUploaded: UInt64 = 0
    private var metadata = InterfaceMetadata()
    private var metadataTime: TimeInterval = -.infinity
    private let observer = NetworkChangeObserver()

    public init() {
        previous = Self.readCounters()
        previousTime = ProcessInfo.processInfo.systemUptime
    }

    /// Re-reading names and addresses means several round trips to `configd`, so it is
    /// done when the system reports a change, plus a slow poll as a safety net.
    private func needsMetadata(at now: TimeInterval) -> Bool {
        let age = now - metadataTime
        return observer.consumeChange() || age >= (observer.isWatching ? 120 : 10)
    }

    public func sample() -> NetworkSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if needsMetadata(at: now) {
            metadata = Self.readMetadata(primary: observer.primaryInterface())
            metadataTime = now
        }
        let current = Self.readCounters()
        let elapsed = now - previousTime
        defer {
            previous = current
            previousTime = now
        }

        var interfaces: [InterfaceSnapshot] = []
        var downloadRate = 0.0, uploadRate = 0.0
        for (name, counters) in current where Self.countsTowardTotal(name, metadata: metadata) {
            let delta = previous[name].map { counters.delta(since: $0) } ?? (received: 0, sent: 0)
            let download = elapsed > 0 ? Double(delta.received) / elapsed : 0
            let upload = elapsed > 0 ? Double(delta.sent) / elapsed : 0
            downloadRate += download
            uploadRate += upload
            sessionDownloaded += delta.received
            sessionUploaded += delta.sent

            let addresses = metadata.addresses[name] ?? []
            guard !addresses.isEmpty || name == metadata.primary else { continue }
            interfaces.append(InterfaceSnapshot(name: name,
                                                displayName: metadata.displayNames[name] ?? name,
                                                isPrimary: name == metadata.primary,
                                                addresses: addresses,
                                                downloadRate: download, uploadRate: upload,
                                                totalDownloaded: counters.received, totalUploaded: counters.sent))
        }
        interfaces.sort { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }
        return NetworkSnapshot(downloadRate: downloadRate, uploadRate: uploadRate,
                               sessionDownloaded: sessionDownloaded, sessionUploaded: sessionUploaded,
                               primaryInterface: metadata.primary, interfaces: interfaces)
    }

    /// Only hardware ports count: traffic through a VPN tunnel also crosses the
    /// physical interface underneath it and would otherwise be counted twice.
    static func countsTowardTotal(_ name: String, metadata: InterfaceMetadata) -> Bool {
        metadata.displayNames.isEmpty ? name.hasPrefix("en") : metadata.displayNames[name] != nil
    }

    static func readCounters() -> [String: InterfaceCounters] {
        var entries = [PulsoInterfaceCounters](repeating: PulsoInterfaceCounters(), count: 64)
        let count = Int(PulsoReadInterfaceCounters(&entries, Int32(entries.count)))
        var result: [String: InterfaceCounters] = [:]
        for entry in entries.prefix(count) {
            let name = withUnsafeBytes(of: entry.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            result[name] = InterfaceCounters(received: entry.bytesIn, sent: entry.bytesOut)
        }
        return result
    }

    static func readMetadata(primary: String?) -> InterfaceMetadata {
        var metadata = InterfaceMetadata()
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            metadata.displayNames[name] = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? name
        }
        metadata.primary = primary
        metadata.addresses = readAddresses()
        return metadata
    }

    /// IPv4 and routable IPv6 addresses per interface, IPv4 first.
    static func readAddresses() -> [String: [String]] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }

        var v4: [String: [String]] = [:], v6: [String: [String]] = [:]
        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = cursor.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            let name = String(cString: cursor.pointee.ifa_name)
            if family == AF_INET {
                v4[name, default: []].append(text)
            } else if !text.hasPrefix("fe80") {
                v6[name, default: []].append(text)
            }
        }
        return v4.merging(v6) { $0 + $1 }
    }
}
