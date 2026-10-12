import PulsoCore
import SwiftUI

/// Module name and a note on the left, the module's main figure on the right.
struct PanelHeader: View {
    var title: String
    var note: String
    var figure: String
    /// Set smaller after the figure, e.g. "MB/s".
    var unit: String?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.panelTitle)
                Text(note).font(.panelNote).foregroundStyle(theme.muted).lineLimit(1).lineBox(13)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(figure).font(.panelFigure).tracking(-0.5)
                if let unit {
                    Text(unit).font(.panelTitle).foregroundStyle(theme.secondary)
                }
            }
            // The figure sits on a 30 pt line, tighter than the font's own.
            .frame(height: 30)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

struct SectionTitle: View {
    var title: String

    @Environment(\.theme) private var theme

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased()).font(.panelSection).tracking(0.63).foregroundStyle(theme.muted).lineLimit(1)
            .lineBox(12)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A heading and what belongs under it.
struct PanelSection<Content: View>: View {
    var title: String
    var spacing: CGFloat = 4
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            SectionTitle(title)
            content
        }
    }
}

/// A name and its value. When the two do not fit, the name is cut short.
struct ValueRow: View {
    var label: String
    var value: String
    /// The series this row is the legend of.
    var swatch: Color?
    /// For a short name with a long value, such as an address: cuts the value short instead.
    var truncatesValue: Bool

    @Environment(\.theme) private var theme

    init(_ label: String, _ value: String, swatch: Color? = nil, truncatesValue: Bool = false) {
        self.label = label
        self.value = value
        self.swatch = swatch
        self.truncatesValue = truncatesValue
    }

    var body: some View {
        HStack(spacing: 8) {
            if let swatch {
                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8)
            }
            Text(label).foregroundStyle(theme.secondary).lineLimit(1).layoutPriority(truncatesValue ? 1 : 0)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().lineLimit(1).layoutPriority(truncatesValue ? 0 : 1)
        }
        .font(.panelRow)
        .frame(height: Metrics.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// A bar that fills with a fraction of its scale.
struct Meter: View {
    var fraction: Double
    var level: Level = .normal
    var height: CGFloat = Metrics.meterHeight

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            // Never shorter than a dot, so a reading at the bottom of its scale still shows.
            Capsule().fill(theme.fill(for: level))
                .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
        }
        .frame(height: height)
        .background(Capsule().fill(theme.track(for: level)))
        .accessibilityHidden(true)
    }
}

/// A reading with a meter under it. Away from normal it gains an icon and a word.
struct MeterRow: View {
    var label: String
    /// Extra context before the value, such as the range of the scale.
    var detail: String?
    var value: String
    var fraction: Double
    var level: Level = .normal

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).foregroundStyle(theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if level != .normal {
                    StatusBadge(level: level).foregroundStyle(theme.secondary)
                }
                if let detail {
                    Text(detail).font(.panelDetail).monospacedDigit().foregroundStyle(theme.muted).lineLimit(1)
                }
                Text(value).monospacedDigit().lineLimit(1).layoutPriority(1)
            }
            .font(.panelRow)
            Meter(fraction: fraction, level: level)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The state of a reading as an icon and a word.
struct StatusBadge: View {
    var level: Level

    var body: some View {
        HStack(spacing: 6) {
            StatusIcon(level: level)
            Text(level.label)
        }
    }
}

struct StatusIcon: View {
    var level: Level

    var body: some View {
        ZStack {
            switch level {
            case .normal:
                Circle().fill(Theme.good)
                Path { path in
                    path.move(to: CGPoint(x: 3.4, y: 6.2))
                    path.addLine(to: CGPoint(x: 5.2, y: 8))
                    path.addLine(to: CGPoint(x: 8.6, y: 4.2))
                }
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            case .warning:
                Path { path in
                    path.move(to: CGPoint(x: 6.5, y: 0.6))
                    path.addLine(to: CGPoint(x: 12.6, y: 11.4))
                    path.addLine(to: CGPoint(x: 0.4, y: 11.4))
                    path.closeSubpath()
                }
                .fill(Theme.warning)
                exclamation(x: 6.5, top: 4.2, dot: 9.4).stroke(Theme.ink, style: Self.markStroke)
            case .critical:
                Circle().fill(Theme.critical)
                exclamation(x: 6, top: 3, dot: 8.8).stroke(.white, style: Self.markStroke)
            }
        }
        .frame(width: level == .warning ? 13 : 12, height: 12)
        .accessibilityHidden(true)
    }

    private static let markStroke = StrokeStyle(lineWidth: 1.5, lineCap: .round)

    private func exclamation(x: CGFloat, top: CGFloat, dot: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: top + 3.4))
            path.move(to: CGPoint(x: x, y: dot))
            path.addLine(to: CGPoint(x: x, y: dot + 0.2))
        }
    }
}

/// Settings on the left, quit on the right, under a rule.
struct PanelFooter: View {
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Rectangle().fill(theme.separator).frame(height: 1)
            HStack {
                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        GearIcon()
                        Text("Ajustes…")
                    }
                    .modifier(FooterLabel())
                }
                Spacer()
                Button(action: onQuit) {
                    Text("Salir").modifier(FooterLabel())
                }
            }
            // A plain style keeps the buttons pure SwiftUI, which ImageRenderer can draw.
            .buttonStyle(.plain)
            .font(.panelRow)
            .foregroundStyle(theme.secondary)
            // The labels, not the hit areas, line up with the panel margin.
            .padding(.horizontal, -8)
        }
    }
}

private struct FooterLabel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
    }
}

private struct GearIcon: View {
    var body: some View {
        Path { path in
            path.addEllipse(in: CGRect(x: 4.5, y: 4.5, width: 4, height: 4))
            let spokes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (6.5, 1, 0, 1.6), (6.5, 10.4, 0, 1.6), (1, 6.5, 1.6, 0), (10.4, 6.5, 1.6, 0),
                (2.6, 2.6, 1.1, 1.1), (9.3, 9.3, 1.1, 1.1), (2.6, 10.4, 1.1, -1.1), (9.3, 3.7, 1.1, -1.1),
            ]
            for (x, y, dx, dy) in spokes {
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + dx, y: y + dy))
            }
        }
        .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

/// A heading with a note at the far end of its line.
struct SectionHeader: View {
    var title: String
    var note: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionTitle(title)
            Spacer(minLength: 8)
            Text(note).font(.panelAxis).foregroundStyle(theme.muted).lineLimit(1)
        }
    }
}

/// Rows of figures under shared column headings.
struct StatsTable: View {
    struct Row {
        var name: String
        /// The series the row belongs to, if it is drawn somewhere.
        var swatch: Color?
        var values: [String]
    }

    /// What the rows have in common, printed over their names.
    var title: String
    var columns: [(title: String, width: CGFloat)]
    var rows: [Row]
    /// Sets the last column back, for a share printed next to the amount it is a share of.
    var dimsLastColumn = false

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                ForEach(columns.indices, id: \.self) { index in
                    Text(columns[index].title).frame(width: columns[index].width, alignment: .trailing)
                }
            }
            .font(.panelAxis)
            .foregroundStyle(theme.muted)
            .frame(height: 16)
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2).fill(row.swatch ?? .clear).frame(width: 8, height: 8)
                        .padding(.trailing, 8)
                    Text(row.name).foregroundStyle(theme.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach(columns.indices, id: \.self) { column in
                        Text(column < row.values.count ? row.values[column] : "")
                            .monospacedDigit().lineLimit(1)
                            .foregroundStyle(dimsLastColumn && column == columns.count - 1 ? theme.secondary : theme.text)
                            .frame(width: columns[column].width, alignment: .trailing)
                    }
                }
                .font(.panelRow)
                .frame(height: Metrics.rowHeight)
                // The rule sits above the row, not inside it.
                .padding(.top, 1)
                .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The latest reading of each series, with its mean and its maximum over the window.
    static func summary(_ title: String, _ series: [(name: String, swatch: Color?, values: [Double])],
                        format: (Double) -> String) -> StatsTable {
        StatsTable(title: title, columns: [("Ahora", 56), ("Media", 56), ("Máx", 56)], rows: series.map { item in
            let mean = item.values.isEmpty ? 0 : item.values.reduce(0, +) / Double(item.values.count)
            return Row(name: item.name, swatch: item.swatch,
                       values: [format(item.values.last ?? 0), format(mean), format(item.values.max() ?? 0)])
        })
    }
}

/// Figures with one more digit than the menu bar and the simple panels use.
enum Precise {
    static func percent(_ fraction: Double) -> String {
        Format.percent(fraction, digits: 1)
    }

    static func temperature(_ celsius: Double, fahrenheit: Bool) -> String {
        Format.number(fahrenheit ? celsius * 9 / 5 + 32 : celsius, digits: 1) + "°"
    }

    /// Storage is decimal (as Finder shows it); memory is binary.
    static func bytes(_ value: UInt64, binary: Bool = false) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        let base: Double = binary ? 1024 : 1000
        var amount = Double(value)
        var index = 0
        while amount >= base && index < units.count - 1 {
            amount /= base
            index += 1
        }
        return Format.number(amount, digits: index == 0 ? 0 : amount >= 100 ? 1 : 2) + " " + units[index]
    }
}
