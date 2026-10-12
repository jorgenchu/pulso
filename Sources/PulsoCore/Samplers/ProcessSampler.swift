import Darwin
import Foundation

public struct ProcessUsage: Codable, Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    /// Percent of one core: 100 means one core fully busy.
    public var cpu: Double
    /// Bytes.
    public var memory: UInt64

    public var id: Int32 { pid }
}

public struct ProcessSnapshot: Codable, Sendable, Equatable {
    public var count: Int
    public var topByCPU: [ProcessUsage]
    public var topByMemory: [ProcessUsage]
}

public struct ProcessSampler {
    public var limit: Int

    public init(limit: Int = 5) {
        self.limit = limit
    }

    /// Lists every process. This spawns `ps`, which is setuid root and so is the only
    /// unprivileged way to see other users' processes; sample it only while it is on screen.
    public func sample() -> ProcessSnapshot? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-c", "-o", "pid=,pcpu=,rss=,comm="]
        // Keep the decimal separator a dot whatever the user's locale is.
        ps.environment = ["LC_ALL": "C"]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        var processes = Self.parse(String(decoding: data, as: UTF8.self))
        processes.removeAll { $0.pid == ps.processIdentifier }
        for index in processes.indices {
            if let footprint = Self.footprint(of: processes[index].pid) {
                processes[index].memory = footprint
            }
        }
        return Self.snapshot(processes, limit: limit)
    }

    static func snapshot(_ processes: [ProcessUsage], limit: Int) -> ProcessSnapshot {
        ProcessSnapshot(count: processes.count,
                        topByCPU: Array(processes.sorted { $0.cpu > $1.cpu }.prefix(limit)),
                        topByMemory: Array(processes.sorted { $0.memory > $1.memory }.prefix(limit)))
    }

    /// Parses `ps -o pid=,pcpu=,rss=,comm=` output. `rss` is in kilobytes.
    static func parse(_ output: String) -> [ProcessUsage] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = UInt64(fields[2]) else { return nil }
            return ProcessUsage(pid: pid, name: fields[3].trimmingCharacters(in: .whitespaces),
                                cpu: cpu, memory: rss * 1024)
        }
    }

    /// The figure Activity Monitor shows as "Memory". Only readable for the user's own
    /// processes, so callers fall back to the resident size reported by `ps`.
    static func footprint(of pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 && info.ri_phys_footprint > 0 ? info.ri_phys_footprint : nil
    }
}
