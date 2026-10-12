import Foundation

public struct SystemSnapshot: Codable, Sendable {
    public var timestamp: Date
    public var cpu: CPUSnapshot
    public var gpus: [GPUSnapshot]
    public var memory: MemorySnapshot?
    public var disk: DiskSnapshot
    public var network: NetworkSnapshot
    public var sensors: SensorsSnapshot
    /// Nil on Macs without a battery.
    public var battery: BatterySnapshot?
    /// Only present while process sampling is enabled.
    public var processes: ProcessSnapshot?
    /// Only present while network process sampling is enabled, and then only once its
    /// first sample has arrived.
    public var networkProcesses: NetworkProcessSnapshot?
}

/// Caches a value that is costly to produce or changes slowly.
struct Throttled<Value> {
    let lifetime: TimeInterval
    private var value: Value?
    private var time: TimeInterval = -.infinity

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    mutating func value(at now: TimeInterval, _ produce: () -> Value) -> Value {
        if let value, now - time < lifetime { return value }
        let fresh = produce()
        value = fresh
        time = now
        return fresh
    }

    mutating func invalidate() {
        value = nil
    }
}

/// Samples every metric on a background queue and reports the result on the main queue.
public final class SystemMonitor {
    /// Called on the main queue after every sample.
    public var onUpdate: ((SystemSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "pulso.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval
    private var samplesProcesses = false
    private var samplesNetworkProcesses = false
    private var isPaused = false

    /// Per-process traffic is the costliest thing Pulso reads, and a list of top talkers
    /// does not need to move faster than this.
    private static let networkProcessInterval: TimeInterval = 3

    private let networkProcesses = NetworkProcessMonitor()
    private let cpu = CPUSampler()
    private let gpu = GPUSampler()
    private let memory = MemorySampler()
    private let disk = DiskSampler()
    private let network = NetworkSampler()
    private let sensorsSampler = SensorsSampler()
    private let batterySampler = BatterySampler()
    private let processSampler = ProcessSampler()

    // Counters are cheap and read on every tick; these are not.
    private var volumes = Throttled<[VolumeInfo]>(lifetime: 30)
    private var battery = Throttled<BatterySnapshot?>(lifetime: 10)
    private var sensors = Throttled<SensorsSnapshot>(lifetime: 3)

    public init(interval: TimeInterval = 2) {
        self.interval = max(0.5, interval)
    }

    public func start() {
        queue.async { self.schedule(firstFire: 0.5) }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.isPaused = false
            self.networkProcesses.stop()
        }
    }

    /// Stops all sampling while nothing can be seen (displays asleep, session locked),
    /// remembering what was running. Does nothing unless the monitor is started.
    public func pause() {
        queue.async {
            guard self.timer != nil else { return }
            self.timer?.cancel()
            self.timer = nil
            self.isPaused = true
            self.networkProcesses.stop()
        }
    }

    /// Undoes `pause()`.
    public func resume() {
        queue.async {
            guard self.isPaused else { return }
            self.isPaused = false
            // Rates are measured between two readings. Reading once now keeps the first
            // sample published from averaging over the whole pause.
            _ = self.sample()
            self.schedule(firstFire: min(1, self.interval))
            if self.samplesNetworkProcesses {
                self.networkProcesses.start(interval: Self.networkProcessInterval)
            }
        }
    }

    public func setInterval(_ interval: TimeInterval) {
        queue.async {
            self.interval = max(0.5, interval)
            if self.timer != nil { self.schedule(firstFire: self.interval) }
        }
    }

    /// Process sampling spawns `ps`, so keep it off unless a process list is visible.
    public func setProcessSampling(_ enabled: Bool) {
        queue.async { self.samplesProcesses = enabled }
    }

    /// Per-process traffic keeps a `nettop` child running, so enable it only while the
    /// list is on screen. The first figures arrive a few seconds after enabling.
    public func setNetworkProcessSampling(_ enabled: Bool) {
        queue.async {
            self.samplesNetworkProcesses = enabled
            if enabled, !self.isPaused {
                self.networkProcesses.start(interval: Self.networkProcessInterval)
            } else if !enabled {
                self.networkProcesses.stop()
            }
        }
    }

    /// Samples as soon as possible, ignoring the slow-metric caches.
    public func refresh() {
        queue.async {
            self.invalidateCaches()
            self.publish(self.sample())
        }
    }

    /// Takes one sample on the calling thread. For command-line use; do not mix with `start()`.
    public func sampleNow(includingProcesses: Bool = false) -> SystemSnapshot {
        queue.sync {
            self.samplesProcesses = includingProcesses
            self.invalidateCaches()
            return self.sample()
        }
    }

    private func schedule(firstFire: TimeInterval) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // The leeway lets the system coalesce wake-ups with other timers.
        timer.schedule(deadline: .now() + firstFire, repeating: interval,
                       leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.publish(self.sample())
        }
        timer.resume()
        self.timer = timer
    }

    private func invalidateCaches() {
        volumes.invalidate()
        battery.invalidate()
        sensors.invalidate()
    }

    private func sample() -> SystemSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let sensors = self.sensors.value(at: now) { sensorsSampler.sample() }
        return SystemSnapshot(
            timestamp: Date(),
            cpu: cpu.sample(),
            gpus: gpu.sample(),
            memory: memory.sample(),
            disk: DiskSnapshot(volumes: volumes.value(at: now) { disk.volumes() },
                               activity: disk.sampleActivity()),
            network: network.sample(),
            sensors: sensors,
            battery: Self.fillingTemperature(of: battery.value(at: now) { batterySampler.sample() }, from: sensors),
            processes: samplesProcesses ? processSampler.sample() : nil,
            networkProcesses: networkProcesses.snapshot())
    }

    static func fillingTemperature(of battery: BatterySnapshot?, from sensors: SensorsSnapshot) -> BatterySnapshot? {
        guard var battery, battery.temperature == nil else { return battery }
        let cells = sensors.temperatures(in: .battery).map(\.celsius)
        if !cells.isEmpty { battery.temperature = cells.reduce(0, +) / Double(cells.count) }
        return battery
    }

    private func publish(_ snapshot: SystemSnapshot) {
        DispatchQueue.main.async { self.onUpdate?(snapshot) }
    }
}
