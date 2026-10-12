import Foundation
import IOKit

public struct VolumeInfo: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String
    public var total: UInt64
    public var available: UInt64
    public var used: UInt64
    public var usedFraction: Double
    public var isRoot: Bool
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isNetwork: Bool
    public var format: String?

    public var id: String { path }
}

public struct DiskActivity: Codable, Sendable, Equatable {
    /// Bytes per second across every block device.
    public var readRate: Double
    public var writeRate: Double
    /// Cumulative bytes since boot.
    public var totalRead: UInt64
    public var totalWritten: UInt64
}

public struct DiskSnapshot: Codable, Sendable, Equatable {
    public var volumes: [VolumeInfo]
    public var activity: DiskActivity

    public var root: VolumeInfo? { volumes.first { $0.isRoot } }
}

struct DiskCounters: Equatable {
    var read: UInt64
    var written: UInt64
}

public final class DiskSampler {
    private var previous: (counters: DiskCounters, time: TimeInterval)?
    /// Whether each block driver, keyed by registry entry ID, is a physical drive.
    /// A device's place in the registry never changes, so each one is classified once.
    private var physicalByEntryID: [UInt64: Bool] = [:]
    /// Per volume path, the space Finder counts as available on top of the free blocks.
    /// Working it out goes through CacheDelete, which scans every mounted volume inside
    /// this process (hundreds of milliseconds with a few disk images mounted), so it is
    /// refreshed rarely. The free blocks are cheap and are read every time.
    private var purgeable: [String: UInt64] = [:]
    private var purgeableTime: TimeInterval = -.infinity
    private let purgeableLifetime: TimeInterval = 300

    public init() {
        if let counters = readCounters() {
            previous = (counters, ProcessInfo.processInfo.systemUptime)
        }
    }

    public func sampleActivity() -> DiskActivity {
        guard let counters = readCounters() else {
            return DiskActivity(readRate: 0, writeRate: 0, totalRead: 0, totalWritten: 0)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = (counters, now) }
        return Self.activity(from: previous?.counters, to: counters, elapsed: now - (previous?.time ?? now))
    }

    static func activity(from previous: DiskCounters?, to current: DiskCounters, elapsed: TimeInterval) -> DiskActivity {
        var readRate = 0.0, writeRate = 0.0
        // A drive being ejected takes its counters with it, so the sum can go backwards.
        if let previous, elapsed > 0 {
            if current.read >= previous.read { readRate = Double(current.read - previous.read) / elapsed }
            if current.written >= previous.written { writeRate = Double(current.written - previous.written) / elapsed }
        }
        return DiskActivity(readRate: readRate, writeRate: writeRate,
                            totalRead: current.read, totalWritten: current.written)
    }

    private func readCounters() -> DiskCounters? {
        var counters = DiskCounters(read: 0, written: 0)
        var found = false
        IORegistry.forEachService(matching: "IOBlockStorageDriver") { service in
            guard isPhysical(service),
                  let statistics = IORegistry.property("Statistics", of: service) as? [String: Any] else { return }
            found = true
            counters.read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            counters.written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? counters : nil
    }

    private func isPhysical(_ service: io_service_t) -> Bool {
        var entryID: UInt64 = 0
        let identified = IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS
        if identified, let known = physicalByEntryID[entryID] { return known }
        let characteristics = IORegistry.inheritedProperty("Protocol Characteristics", of: service) as? [String: Any]
        let physical = Self.isPhysical(protocolCharacteristics: characteristics)
        if identified { physicalByEntryID[entryID] = physical }
        return physical
    }

    /// A mounted disk image is a block device too, but its I/O already shows up on the
    /// drive holding the image file, so counting both would report the same bytes twice.
    static func isPhysical(protocolCharacteristics: [String: Any]?) -> Bool {
        (protocolCharacteristics?["Physical Interconnect"] as? String) != "Virtual Interface"
    }

    static func purgeableSpace(importantUsage: Int64, freeBlocks: UInt64) -> UInt64 {
        importantUsage > Int64(clamping: freeBlocks) ? UInt64(importantUsage) - freeBlocks : 0
    }

    /// The mounted volumes a user would recognise (hidden system and disk image volumes are left out).
    public func volumes() -> [VolumeInfo] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsLocalKey, .volumeLocalizedFormatDescriptionKey,
        ]
        let now = ProcessInfo.processInfo.systemUptime
        let refreshesPurgeable = now - purgeableTime >= purgeableLifetime
        if refreshesPurgeable {
            purgeable.removeAll()
            purgeableTime = now
        }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let capacity = UInt64(total)
            let freeBlocks = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            if refreshesPurgeable {
                // Reads 0 on file systems without purgeable space.
                let important = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? 0
                purgeable[url.path] = Self.purgeableSpace(importantUsage: important, freeBlocks: freeBlocks)
            }
            let available = min(capacity, freeBlocks + (purgeable[url.path] ?? 0))
            let used = capacity - available
            return VolumeInfo(name: values.volumeName ?? url.lastPathComponent,
                              path: url.path,
                              total: capacity,
                              available: available,
                              used: used,
                              usedFraction: Double(used) / Double(capacity),
                              isRoot: url.path == "/",
                              isInternal: values.volumeIsInternal ?? false,
                              isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false),
                              isNetwork: !(values.volumeIsLocal ?? true),
                              format: values.volumeLocalizedFormatDescription)
        }
    }
}
