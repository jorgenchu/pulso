import PulsoCore
import SwiftUI

struct BatteryPanel: View {
    let battery: BatterySnapshot
    let fahrenheit: Bool
    let hidden: Set<PanelSectionKind>

    var body: some View {
        PanelHeader(title: "Batería", note: note, figure: Format.percent(battery.charge))

        Meter(fraction: battery.charge, height: 10)

        VStack(spacing: 0) {
            ValueRow("Estado", state)
            if battery.isCharging || !battery.isPluggedIn {
                ValueRow(battery.isCharging ? "Hasta carga completa" : "Tiempo restante", remaining ?? "Calculando…")
            }
            if let power = battery.power {
                ValueRow("Potencia", Self.signed(power) + " W")
            }
            if let watts = battery.adapterWatts, battery.isPluggedIn {
                ValueRow("Adaptador", "\(watts) W")
            }
        }

        if !hidden.contains(.batteryHealth), battery.health != nil || battery.cycleCount != nil || battery.temperature != nil {
            PanelSection(title: "Salud", spacing: 6) {
                if let health = battery.health {
                    MeterRow(label: "Capacidad máxima", detail: capacity, value: Format.percent(health), fraction: health)
                }
                VStack(spacing: 0) {
                    if let cycles = battery.cycleCount {
                        ValueRow("Ciclos", "\(cycles)")
                    }
                    if let temperature = battery.temperature {
                        ValueRow("Temperatura", Format.temperature(temperature, fahrenheit: fahrenheit))
                    }
                }
            }
        }
    }

    private var state: String {
        if battery.isCharging { return "Cargando" }
        if battery.isPluggedIn { return battery.isFullyCharged ? "Carga completa" : "Conectado, sin cargar" }
        return "Con batería"
    }

    private var remaining: String? {
        battery.minutesRemaining.map(Format.hoursMinutes)
    }

    private var note: String {
        guard let remaining, battery.isCharging || !battery.isPluggedIn else { return state }
        return "\(state) · \(battery.isCharging ? "faltan" : "quedan") \(remaining)"
    }

    /// "6818 de 8694 mAh": what the battery holds now against what it held when new.
    private var capacity: String? {
        guard let maximum = battery.maximumCapacity, let design = battery.designCapacity else { return nil }
        return "\(maximum) de \(design) mAh"
    }

    /// Watts into the battery carry a plus sign and watts out of it a minus sign.
    private static func signed(_ watts: Double) -> String {
        let magnitude = Format.number(abs(watts), digits: 1)
        return abs(watts) < 0.05 ? magnitude : (watts < 0 ? "−" : "+") + magnitude
    }
}
