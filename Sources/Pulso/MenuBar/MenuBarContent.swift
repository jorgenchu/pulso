import Foundation
import PulsoCore

/// What one status item shows, independent of how it is drawn. Everything in it is
/// already rounded to what the item can resolve, so two contents are equal exactly when
/// they draw the same image, and an item is only redrawn when it would look different.
enum MenuBarContent: Equatable {
    /// A small tag, a glyph and a value, any of the first two optional: `CPU ▂▃▅ 12%`.
    /// The width of `widest` is reserved for the value, so that the neighbouring items
    /// do not shift while the value stays within it.
    case value(label: String?, glyph: Glyph?, text: String, widest: String)
    /// Two right-aligned lines, used for upload over download.
    case stacked(top: String, bottom: String, widest: String)

    /// A small drawing between the tag and the value. Sizes are in points.
    enum Glyph: Equatable {
        /// The height of each bar, left to right, in a row with room for `slots` bars.
        /// With fewer bars than slots, the bars keep to the right.
        case bars([Int], slots: Int)
        /// A pill of `pillWidth`, filled from the left up to this width.
        case pill(Double)
        /// A battery whose `batteryWidth` of charge is filled up to this width.
        case battery(Double)

        static let historyLength = 10
        static let barHeight = 12
        static let pillWidth: Double = 22
        static let batteryWidth: Double = 16

        /// The most recent values, as fractions, oldest first.
        static func bars(history: [Double]) -> Glyph {
            .bars(history.suffix(historyLength).map(height), slots: historyLength)
        }

        /// One bar per value.
        static func bars(levels: [Double]) -> Glyph {
            .bars(levels.map(height), slots: levels.count)
        }

        /// Never less than 1 pt, so an idle reading still leaves a mark.
        private static func height(of fraction: Double) -> Int {
            max(1, Int((unit(fraction) * Double(barHeight)).rounded()))
        }

        static func pill(fraction: Double) -> Glyph {
            .pill(halfPoints(unit(fraction) * pillWidth))
        }

        static func battery(charge: Double) -> Glyph {
            .battery(halfPoints(unit(charge) * batteryWidth))
        }

        private static func unit(_ fraction: Double) -> Double {
            min(1, max(0, fraction))
        }

        /// Half a point is one pixel on a Retina display; nothing finer can be seen.
        private static func halfPoints(_ value: Double) -> Double {
            (value * 2).rounded() / 2
        }
    }

    /// Shown until the first sample arrives.
    static func placeholder(for kind: ModuleKind) -> MenuBarContent {
        .value(label: kind.shortLabel, glyph: nil, text: "–", widest: "00%")
    }

    /// Returns nil when the module has nothing to show on this machine.
    @MainActor
    static func make(for kind: ModuleKind, snapshot: SystemSnapshot, history: MetricHistory,
                     settings: AppSettings) -> MenuBarContent? {
        switch kind {
        case .cpu:
            let load = CPULoad(snapshot.cpu, ignoring: settings.ignoredCores)
            let glyph: Glyph?
            switch settings.cpuGlyph {
            case .history: glyph = .bars(history: history.values(\.cpu))
            case .cores: glyph = .bars(levels: load.cores.map(\.usage))
            case .none: glyph = nil
            }
            return .value(label: kind.shortLabel, glyph: glyph, text: Format.percent(load.usage), widest: "00%")
        case .gpu:
            guard let utilization = snapshot.gpus.first?.utilization else { return nil }
            return .value(label: kind.shortLabel, glyph: nil, text: Format.percent(utilization), widest: "00%")
        case .memory:
            guard let memory = snapshot.memory else { return nil }
            let glyph = settings.memoryShowsPill ? Glyph.pill(fraction: memory.usedFraction) : nil
            switch settings.memoryValue {
            case .percent:
                return .value(label: kind.shortLabel, glyph: glyph, text: Format.percent(memory.usedFraction), widest: "00%")
            case .used:
                return .value(label: kind.shortLabel, glyph: glyph, text: Format.bytes(memory.used, binary: true),
                              widest: "00,0 GB")
            }
        case .disk:
            guard let root = snapshot.disk.root else { return nil }
            switch settings.diskValue {
            case .used:
                return .value(label: kind.shortLabel, glyph: nil, text: Format.percent(root.usedFraction), widest: "00%")
            case .free:
                return .value(label: kind.shortLabel, glyph: nil, text: Format.bytes(root.available), widest: "000 GB")
            }
        case .network:
            let upload = "↑ " + Format.rate(snapshot.network.uploadRate)
            let download = "↓ " + Format.rate(snapshot.network.downloadRate)
            switch settings.networkTraffic {
            case .both: return .stacked(top: upload, bottom: download, widest: "↓ 9,99 MB/s")
            case .download: return .value(label: nil, glyph: nil, text: download, widest: "↓ 9,99 MB/s")
            case .upload: return .value(label: nil, glyph: nil, text: upload, widest: "↑ 9,99 MB/s")
            }
        case .sensors:
            let sensors = snapshot.sensors
            let reading: (label: String?, celsius: Double?)
            switch settings.sensorSource {
            case .cpu: reading = (kind.shortLabel, sensors.cpuTemperature)
            case .gpu: reading = ("GPU", sensors.gpuTemperature)
            case .hottest: reading = (kind.shortLabel, sensors.hottest)
            }
            // A machine without the chosen sensor still shows the next best thing.
            guard let temperature = reading.celsius ?? sensors.cpuTemperature ?? sensors.hottest else { return nil }
            return .value(label: reading.celsius == nil ? kind.shortLabel : reading.label, glyph: nil,
                          text: Format.temperature(temperature, fahrenheit: settings.usesFahrenheit), widest: "00°")
        case .battery:
            guard let battery = snapshot.battery else { return nil }
            let glyph = Glyph.battery(charge: battery.charge)
            // There is no time to show while the system is still estimating, or on a full charge.
            if settings.batteryValue == .time, let minutes = battery.minutesRemaining,
               battery.isCharging || !battery.isPluggedIn {
                return .value(label: nil, glyph: glyph, text: Format.hoursMinutes(minutes), widest: "0:00")
            }
            return .value(label: nil, glyph: glyph, text: Format.percent(battery.charge), widest: "00%")
        }
    }
}
