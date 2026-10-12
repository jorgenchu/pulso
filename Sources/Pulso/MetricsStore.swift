import Combine
import Foundation
import PulsoCore

/// One moment of the metrics that are drawn over time.
struct MetricSample {
    /// Seconds on a clock that only matters relative to the other samples.
    var time: TimeInterval
    /// Fractions of the monitored cores' time, 0...1.
    var cpuUser = 0.0
    var cpuSystem = 0.0
    /// Usage of every core, monitored or not, by index.
    var cores: [Double] = []
    /// Fractions, 0...1. The total is the busier of the two stages.
    var gpu = 0.0
    var gpuRender: Double?
    var gpuGeometry: Double?
    /// Bytes.
    var gpuMemory = 0.0
    var memoryUsed = 0.0
    /// Bytes.
    var memoryApp = 0.0
    var memoryWired = 0.0
    var memoryCompressed = 0.0
    var memoryCached = 0.0
    /// Bytes per second.
    var download = 0.0
    var upload = 0.0
    var diskRead = 0.0
    var diskWrite = 0.0
    /// °C.
    var cpuTemperature: Double?
    var gpuTemperature: Double?

    var cpu: Double { min(1, cpuUser + cpuSystem) }
}

/// The recent samples: everything inside a window that ends at the newest one.
struct MetricHistory {
    /// How far back the panels look.
    static let span: TimeInterval = 120

    var window: TimeInterval = MetricHistory.span
    private(set) var samples: [MetricSample] = []

    init() {}

    /// A history made up for a review render.
    init(samples: [MetricSample]) {
        self.samples = samples
    }

    var isEmpty: Bool { samples.isEmpty }

    /// `ignoredCores` are left out of the CPU figures. The load of each core is only kept
    /// `perCore`, for the panels that draw it. `time` overrides the snapshot's own.
    mutating func record(_ snapshot: SystemSnapshot, ignoredCores: Set<Int>, perCore: Bool, time: TimeInterval? = nil) {
        let load = CPULoad(snapshot.cpu, ignoring: ignoredCores)
        let gpu = snapshot.gpus.first
        let memory = snapshot.memory
        samples.append(MetricSample(
            time: time ?? snapshot.timestamp.timeIntervalSinceReferenceDate,
            cpuUser: load.user, cpuSystem: load.system, cores: perCore ? snapshot.cpu.cores.map(\.usage) : [],
            gpu: gpu?.utilization ?? 0, gpuRender: gpu?.rendererUtilization, gpuGeometry: gpu?.tilerUtilization,
            gpuMemory: Double(gpu?.memoryInUse ?? 0),
            memoryUsed: memory?.usedFraction ?? 0, memoryApp: Double(memory?.app ?? 0),
            memoryWired: Double(memory?.wired ?? 0), memoryCompressed: Double(memory?.compressed ?? 0),
            memoryCached: Double(memory?.cached ?? 0),
            download: snapshot.network.downloadRate, upload: snapshot.network.uploadRate,
            diskRead: snapshot.disk.activity.readRate, diskWrite: snapshot.disk.activity.writeRate,
            cpuTemperature: snapshot.sensors.cpuTemperature, gpuTemperature: snapshot.sensors.gpuTemperature))
        trim()
    }

    /// The same samples seen through a shorter window.
    func last(_ seconds: TimeInterval) -> MetricHistory {
        var recent = self
        recent.window = seconds
        recent.trim()
        return recent
    }

    /// The samples that pass a test, in the same window.
    func filtered(_ isIncluded: (MetricSample) -> Bool) -> MetricHistory {
        var subset = self
        subset.samples = samples.filter(isIncluded)
        return subset
    }

    /// One reading per sample, oldest first.
    func values(_ reading: (MetricSample) -> Double) -> [Double] {
        samples.map(reading)
    }

    /// Where each sample falls in the window: 0 at its start, 1 at the newest sample.
    var positions: [Double] {
        guard let newest = samples.last?.time else { return [] }
        return samples.map { max(0, 1 - (newest - $0.time) / window) }
    }

    /// How long ago each sample was taken, in seconds.
    var ages: [TimeInterval] {
        guard let newest = samples.last?.time else { return [] }
        return samples.map { newest - $0.time }
    }

    private mutating func trim() {
        guard let newest = samples.last?.time else { return }
        // The clock going backwards would leave samples from the future; drop those too.
        samples.removeAll { $0.time < newest - window - 0.01 || $0.time > newest }
    }
}

/// Bridges the sampling engine to the UI: the latest snapshot plus history.
@MainActor
final class MetricsStore: ObservableObject {
    /// How often an open panel refreshes, whatever the menu bar is set to.
    static let panelInterval: TimeInterval = 1

    @Published private(set) var snapshot: SystemSnapshot?
    private(set) var history = MetricHistory()
    /// The highest reading of each temperature sensor since Pulso started, by sensor name.
    private(set) var temperaturePeaks: [String: Double] = [:]
    /// Cores left out of the CPU history. Changing them starts the history afresh,
    /// since the old samples measured something else.
    var ignoredCores: Set<Int> = [] {
        didSet {
            if ignoredCores != oldValue { history = MetricHistory() }
        }
    }
    /// Whether the history keeps the load of each core, which only the advanced CPU panel draws.
    var recordsCores = false
    /// Spaces the samples this far apart in the history whatever the real time between
    /// them, so that a review render can fill the window quickly.
    var historyStep: TimeInterval?

    private let monitor: SystemMonitor
    private var interval: TimeInterval
    private var openPanels = 0
    private var sampleCount = 0
    private var lowPower: NSObjectProtocol?

    init(interval: TimeInterval) {
        self.interval = interval
        monitor = SystemMonitor(interval: interval)
        monitor.onUpdate = { [weak self] snapshot in
            // SystemMonitor delivers on the main queue.
            MainActor.assumeIsolated { self?.ingest(snapshot) }
        }
        applyInterval()
        lowPower = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyInterval() }
        }
    }

    /// How often the menu bar is refreshed: the interval in the settings, or twice that
    /// while the system is in Low Power Mode.
    var barInterval: TimeInterval {
        interval * (ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 1)
    }

    func start() {
        monitor.start()
    }

    /// How often the menu bar refreshes.
    func setInterval(_ interval: TimeInterval) {
        self.interval = interval
        applyInterval()
    }

    /// Nothing is measured while nothing can be seen: displays asleep or session locked.
    func setPaused(_ paused: Bool) {
        if paused {
            monitor.pause()
        } else {
            monitor.resume()
        }
    }

    /// Samples right away instead of waiting for the next tick.
    func refresh() {
        monitor.refresh()
    }

    /// An open panel refreshes every second; with all of them closed the menu bar's own
    /// pace is back.
    func setPanelOpen(_ open: Bool) {
        openPanels = max(0, openPanels + (open ? 1 : -1))
        applyInterval()
        if open { monitor.refresh() }
    }

    /// Process lists are only sampled while one is on screen.
    func setProcessListVisible(_ visible: Bool) {
        monitor.setProcessSampling(visible)
        if visible { monitor.refresh() }
    }

    /// Traffic per process keeps a helper process running, so only while its list is on screen.
    func setNetworkProcessListVisible(_ visible: Bool) {
        monitor.setNetworkProcessSampling(visible)
    }

    /// Stops sampling for good. The engine ends its traffic helper on its own queue, so
    /// this waits a moment for that before the process goes away; the helper would
    /// otherwise outlive the app.
    func shutDown() {
        monitor.setNetworkProcessSampling(false)
        monitor.stop()
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func applyInterval() {
        monitor.setInterval(openPanels > 0 ? min(barInterval, Self.panelInterval) : barInterval)
    }

    private func ingest(_ snapshot: SystemSnapshot) {
        // History first: observers of `snapshot` read it as soon as the value changes.
        sampleCount += 1
        history.record(snapshot, ignoredCores: ignoredCores, perCore: recordsCores,
                       time: historyStep.map { Double(sampleCount) * $0 })
        for reading in snapshot.sensors.temperatures {
            temperaturePeaks[reading.name] = max(temperaturePeaks[reading.name] ?? reading.celsius, reading.celsius)
        }
        self.snapshot = snapshot
    }
}
