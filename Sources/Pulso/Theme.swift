import SwiftUI

/// The colours of the "Instrumento" design, one set per appearance. Text never takes a
/// series colour, and the status colours are kept for warnings.
struct Theme: Equatable {
    // Surfaces
    let panel: Color
    /// A card that groups rows on top of the panel.
    let group: Color
    /// A recessed surface, behind a segmented control.
    let well: Color
    /// A surface that floats over the panel, such as a graph readout.
    let raised: Color
    /// Grid lines inside a graph.
    let hairline: Color
    /// The axis a graph grows from.
    let axis: Color
    /// The 1 px edge of a panel.
    let outline: Color
    /// Rules between rows and above the footer.
    let separator: Color

    // Text
    let text: Color
    let secondary: Color
    let muted: Color

    // Series, always used in this order.
    let blue: Color
    let orange: Color
    let aqua: Color
    let yellow: Color
    /// The unused share of a stacked bar.
    let idle: Color

    /// Opacity of the track behind a meter or a core column.
    let trackOpacity: Double
    /// Opacity of the area under the first and the second line of a graph, and under
    /// a line that is on its own.
    let areaOpacity: Double
    let secondAreaOpacity: Double
    let singleAreaOpacity: Double

    static let dark = Theme(
        panel: Color(hex: 0x1A1B1D), group: Color(hex: 0x232528), well: Color(hex: 0x17181A),
        raised: Color(hex: 0x2A2D31), hairline: Color(hex: 0x2A2C2F), axis: Color(hex: 0x3A3C40),
        outline: .white.opacity(0.10), separator: .white.opacity(0.08),
        text: Color(hex: 0xF4F5F6), secondary: Color(hex: 0xB4B8BE), muted: Color(hex: 0x8B9097),
        blue: Color(hex: 0x3987E5), orange: Color(hex: 0xD95926), aqua: Color(hex: 0x199E70),
        yellow: Color(hex: 0xC98500), idle: .white.opacity(0.10),
        trackOpacity: 0.18, areaOpacity: 0.16, secondAreaOpacity: 0.18, singleAreaOpacity: 0.14)

    static let light = Theme(
        panel: Color(hex: 0xF7F7F5), group: Color(hex: 0xECECE9), well: Color(hex: 0xDFDFDB),
        raised: .white, hairline: Color(hex: 0xE3E3DF), axis: Color(hex: 0xC6C6C1),
        outline: .black.opacity(0.10), separator: .black.opacity(0.08),
        text: Color(hex: 0x111213), secondary: Color(hex: 0x55585D), muted: Color(hex: 0x696D73),
        blue: Color(hex: 0x2A78D6), orange: Color(hex: 0xEB6834), aqua: Color(hex: 0x1BAF7A),
        yellow: Color(hex: 0xEDA100), idle: .black.opacity(0.10),
        trackOpacity: 0.16, areaOpacity: 0.12, secondAreaOpacity: 0.16, singleAreaOpacity: 0.10)

    // Status colours are the same in both appearances.
    static let good = Color(hex: 0x0CA30C)
    static let warning = Color(hex: 0xFAB219)
    static let serious = Color(hex: 0xEC835A)
    static let critical = Color(hex: 0xD03B3B)
    /// The mark drawn on top of a good or warning icon.
    static let ink = Color(hex: 0x0E0F10)
    /// A selected segment, dark enough to carry white text.
    static let selection = Color(hex: 0x256ABF)

    /// The bar of a meter: blue until the reading needs attention.
    func fill(for level: Level) -> Color {
        switch level {
        case .normal: return blue
        case .warning: return Self.warning
        case .critical: return Self.critical
        }
    }

    func track(for level: Level) -> Color {
        switch level {
        case .normal: return blue.opacity(trackOpacity)
        case .warning: return Self.warning.opacity(0.20)
        case .critical: return Self.critical.opacity(0.28)
        }
    }
}

/// How far a reading is from normal. Always shown as an icon and a word, never by colour alone.
enum Level {
    case normal, warning, critical

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Alta"
        case .critical: return "Crítica"
        }
    }
}

extension EnvironmentValues {
    /// Follows the colour scheme, so every view tracks the system appearance.
    var theme: Theme {
        colorScheme == .dark ? .dark : .light
    }
}

extension NSColor {
    /// The panel surface as a colour that follows the appearance of whatever draws it.
    static let panelSurface = NSColor(name: nil) { appearance in
        NSColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Theme.dark.panel : Theme.light.panel)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The type scale. Sizes are in points; the family is the system font.
extension Font {
    /// The main figure of a panel. Proportional figures: it stands alone.
    static let panelFigure = Font.system(size: 30, weight: .semibold)
    static let panelTitle = Font.system(size: 13, weight: .semibold)
    static let panelRow = Font.system(size: 12.5)
    static let panelNote = Font.system(size: 11.5)
    /// Secondary detail next to a row value.
    static let panelDetail = Font.system(size: 11)
    /// Section headings; set in uppercase with 6 % tracking.
    static let panelSection = Font.system(size: 10.5, weight: .semibold)
    static let panelAxis = Font.system(size: 10)
    /// The scale printed inside a graph.
    static let panelScale = Font.system(size: 9.5)
    /// The name of a setting.
    static let settingsRow = Font.system(size: 13)
}

extension View {
    /// Sets a single line of text on a line of the given height. Left alone, the system
    /// gives the small sizes a line 1 pt taller than the type scale's.
    func lineBox(_ height: CGFloat) -> some View {
        frame(height: height)
    }
}

enum Metrics {
    static let panelWidth: CGFloat = 340
    static let margin: CGFloat = 16
    static let panelRadius: CGFloat = 14
    static let sectionSpacing: CGFloat = 16
    static let rowHeight: CGFloat = 22
    static let meterHeight: CGFloat = 4
    static let coreColumn = CGSize(width: 22, height: 44)
    static let menuBarItemHeight: CGFloat = 22
}
