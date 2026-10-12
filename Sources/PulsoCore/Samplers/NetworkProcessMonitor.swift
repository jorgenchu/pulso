import Darwin
import Foundation

public struct ProcessTraffic: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// How many processes share the name and are counted together, e.g. the helpers of one browser.
    public var processCount: Int
    /// Bytes per second.
    public var downloadRate: Double
    public var uploadRate: Double

    public var id: String { name }
    public var totalRate: Double { downloadRate + uploadRate }
}

public struct NetworkProcessSnapshot: Codable, Sendable, Equatable {
    /// The busiest names, most traffic first.
    public var top: [ProcessTraffic]
    /// Everything with traffic that did not make the list, summed.
    public var otherCount: Int
    public var otherDownloadRate: Double
    public var otherUploadRate: Double
}

/// One process in one `nettop` sample.
struct TrafficSample: Equatable {
    var name: String
    var pid: Int32
    var received: UInt64
    var sent: UInt64
}

/// Per-process network traffic, read from a long-lived `nettop` child.
///
/// The kernel only hands per-process counters to the NetworkStatistics machinery behind
/// `nettop`, and walking every socket costs about 30 ms of CPU per sample. So this runs
/// only between `start()` and `stop()`: call them as the list comes on and goes off screen.
public final class NetworkProcessMonitor {
    public var limit = 5

    private let lock = NSLock()
    private var process: Process?
    private var reader: FileHandle?
    private var pending = Data()
    private var block: [TrafficSample] = []
    private var blockStart: TimeInterval?
    private var blocksSeen = 0
    private var names: [Int32: String] = [:]
    private var latest: NetworkProcessSnapshot?

    public init() {}

    deinit {
        stop()
    }

    public var isRunning: Bool {
        lock.withLock { process != nil }
    }

    /// The most recent complete sample, or nil until one arrives (about two intervals after `start`).
    public func snapshot() -> NetworkProcessSnapshot? {
        lock.withLock { latest }
    }

    public func start(interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { return }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -P: one row per process. -x: raw byte counts. -d: change since the previous sample.
        // -L 0: keep sampling until killed. -t external: leave out loopback, where local
        // processes talking to each other would otherwise top the list without touching the network.
        child.arguments = ["-P", "-x", "-d", "-L", "0", "-s", String(max(1, Int(interval.rounded()))),
                           "-t", "external", "-J", "bytes_in,bytes_out"]
        // nettop writes through C stdio, which holds output back in large blocks unless it
        // is talking to a terminal; over a pipe, samples would arrive several at a time and
        // late. A pseudo-terminal makes it flush line by line. It also means that if Pulso
        // dies the terminal goes away and nettop is hung up instead of lingering.
        var primary: Int32 = -1, secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { return }
        let reader = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        child.standardOutput = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        reader.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        do {
            try child.run()
            process = child
            self.reader = reader
        } catch {
            reader.readabilityHandler = nil
        }
    }

    public func stop() {
        lock.lock()
        let child = process, reader = self.reader
        process = nil
        self.reader = nil
        pending.removeAll()
        block.removeAll()
        blockStart = nil
        blocksSeen = 0
        names.removeAll()
        latest = nil
        lock.unlock()

        guard let child else { return }
        reader?.readabilityHandler = nil
        child.terminate()
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard process != nil else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            // A terminal ends lines with a carriage return and a line feed.
            if line.hasSuffix("\r") { line.removeLast() }
            handle(line: line)
        }
    }

    /// A header line opens a sample; the next header closes it.
    private func handle(line: String) {
        guard Self.isHeader(line) else {
            if let sample = Self.parse(line: line) { block.append(sample) }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // The first sample holds totals since each process started, not a change.
        if let start = blockStart, blocksSeen >= 2, now > start {
            latest = Self.snapshot(from: block, elapsed: now - start, limit: limit) { resolveName(of: $0) }
            names = names.filter { pid, _ in block.contains { $0.pid == pid } }
        }
        block.removeAll(keepingCapacity: true)
        blockStart = now
        blocksSeen += 1
    }

    /// `nettop` cuts names at 15 characters; the executable's own name is complete.
    private func resolveName(of sample: TrafficSample) -> String {
        if let known = names[sample.pid] { return known }
        var path = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(sample.pid, &path, UInt32(path.count))
        let name = length > 0 ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : sample.name
        names[sample.pid] = name
        return name
    }

    // MARK: Parsing

    static func isHeader(_ line: String) -> Bool {
        line.hasPrefix(",bytes_in")
    }

    /// Parses `name.pid,bytes_in,bytes_out,`. The name may itself contain dots and commas,
    /// so the fields are taken from the right.
    static func parse(line: String) -> TrafficSample? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count >= 3,
              let sent = UInt64(fields[fields.count - 1]),
              let received = UInt64(fields[fields.count - 2]) else { return nil }
        let identity = fields[..<(fields.count - 2)].joined(separator: ",")
        guard let dot = identity.lastIndex(of: "."),
              let pid = Int32(identity[identity.index(after: dot)...]) else { return nil }
        return TrafficSample(name: String(identity[..<dot]), pid: pid, received: received, sent: sent)
    }

    /// Turns one sample of byte changes into rates, merging processes that share a name.
    static func snapshot(from samples: [TrafficSample], elapsed: TimeInterval, limit: Int,
                         name: (TrafficSample) -> String) -> NetworkProcessSnapshot {
        var byName: [String: ProcessTraffic] = [:]
        for sample in samples where sample.received > 0 || sample.sent > 0 {
            let key = name(sample)
            var entry = byName[key] ?? ProcessTraffic(name: key, processCount: 0, downloadRate: 0, uploadRate: 0)
            entry.processCount += 1
            entry.downloadRate += Double(sample.received) / elapsed
            entry.uploadRate += Double(sample.sent) / elapsed
            byName[key] = entry
        }
        // Ties broken by name so that the order does not flicker between samples.
        let ranked = byName.values.sorted { ($0.totalRate, $1.name) > ($1.totalRate, $0.name) }
        let rest = ranked.dropFirst(limit)
        return NetworkProcessSnapshot(top: Array(ranked.prefix(limit)),
                                      otherCount: rest.count,
                                      otherDownloadRate: rest.reduce(0) { $0 + $1.downloadRate },
                                      otherUploadRate: rest.reduce(0) { $0 + $1.uploadRate })
    }
}
