import Foundation

/// Compact, width-stable formatting for values shown in the menu bar and panels.
public enum Format {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Formats a byte count. Storage is decimal (as Finder shows it); memory is binary.
    public static func bytes(_ value: UInt64, binary: Bool = false) -> String {
        let base: Double = binary ? 1024 : 1000
        var amount = Double(value)
        var index = 0
        while amount >= base && index < units.count - 1 {
            amount /= base
            index += 1
        }
        let digits = (index == 0 || amount >= 100) ? 0 : (amount >= 10 ? 1 : 2)
        return number(amount, digits: digits) + " " + units[index]
    }

    /// Formats a transfer rate. Never drops below KB/s so the width stays stable.
    public static func rate(_ bytesPerSecond: Double) -> String {
        var amount = max(0, bytesPerSecond) / 1000
        var index = 1
        while amount >= 1000 && index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        let digits = (index == 1 || amount >= 100) ? 0 : (amount >= 10 ? 1 : 2)
        return number(amount, digits: digits) + " " + units[index] + "/s"
    }

    public static func percent(_ fraction: Double, digits: Int = 0) -> String {
        number(max(0, fraction) * 100, digits: digits) + "%"
    }

    public static func temperature(_ celsius: Double, fahrenheit: Bool = false) -> String {
        number(fahrenheit ? celsius * 9 / 5 + 32 : celsius, digits: 0) + "°"
    }

    /// "3:07" for a duration given in minutes.
    public static func hoursMinutes(_ minutes: Int) -> String {
        "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// "4 d 3 h", "3 h 12 min" or "12 min".
    public static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }

    public static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", locale: .current, value)
    }
}
