import PulsoCore
import SwiftUI

/// One line of a history graph and the area it encloses.
struct GraphTrace {
    var name: String
    var color: Color
    /// Opacity of the area between the line and `base`; 0 leaves it empty.
    var fillOpacity: Double
    /// Where the line runs, oldest sample first: 0 is the bottom edge of the graph, 1 the top.
    var levels: [Double]
    /// Where the filled area ends, for each sample.
    var base: [Double]
    /// Whether the line itself is drawn. Without it the trace is only an area.
    var isLine = true
    /// The reading of a sample, shown while the pointer is over it.
    var reading: (Int) -> String

    init(name: String, color: Color, fillOpacity: Double, levels: [Double], base: [Double], isLine: Bool = true,
         reading: @escaping (Int) -> String) {
        self.name = name
        self.color = color
        self.fillOpacity = fillOpacity
        self.levels = levels
        self.base = base
        self.isLine = isLine
        self.reading = reading
    }

    /// A line whose area reaches down (or up) to a fixed level.
    init(name: String, color: Color, fillOpacity: Double, levels: [Double], base: Double = 0, isLine: Bool = true,
         reading: @escaping (Int) -> String) {
        self.init(name: name, color: color, fillOpacity: fillOpacity, levels: levels,
                  base: Array(repeating: base, count: levels.count), isLine: isLine, reading: reading)
    }
}

/// The recent history of a few readings. Samples sit where their time puts them, so a
/// history that has just started grows in from the right.
struct HistoryGraph: View {
    enum Axis {
        case bottom, middle
    }

    /// What the advanced mode adds around the plot: a scale on the right, time marks
    /// underneath, the peak and where each line ends.
    struct Detail {
        struct Mark {
            /// 0 is the bottom edge of the plot, 1 the top.
            var level: Double
            var label: String
            var isAxis = false
        }

        var marks: [Mark]
        /// The trace whose highest point is circled, and how that sample reads.
        var peak: (trace: Int, label: (Int) -> String)?
        /// A level worth a warning, drawn across the plot.
        var threshold: (level: Double, label: String)?
        /// Whether each line is marked with a dot where it ends.
        var endDots = true
        /// How far from the top edge the peak must be for its value to go above it.
        var peakClearance: CGFloat = 20

        /// Quarters of a scale that starts at zero.
        static func quarters(_ label: (Double) -> String) -> [Mark] {
            [1, 0.75, 0.5, 0.25, 0].map { Mark(level: $0, label: label($0), isAxis: $0 == 0) }
        }
    }

    var height: CGFloat
    var axis: Axis = .bottom
    /// The samples the traces were read from; it places them in time.
    var timeline: MetricHistory
    var traces: [GraphTrace]
    /// The value at the top edge, and at the bottom edge when that is not zero.
    var topLabel = ""
    var bottomLabel: String?
    var detail: Detail?
    var description: String
    /// A sample to show the readout for, as if the pointer were over it.
    var pinnedSample: Int?

    @Environment(\.theme) private var theme
    @Environment(\.graphStyle) private var style
    @State private var hoveredSample: Int?

    /// Room for the scale to the right of a detailed plot.
    private static let scaleWidth: CGFloat = 34

    var body: some View {
        if let detail {
            detailed(detail)
        } else {
            simple
        }
    }

    // MARK: Simple

    private var simple: some View {
        VStack(spacing: 6) {
            plot(lineWidth: 2)
                .frame(height: height)
                .clipped()
                .background { grid }
                // Backed by the panel colour, which only shows where a line or an area runs behind the label.
                .overlay(alignment: .topLeading) {
                    scaleLabel(topLabel).padding(.trailing, 3).background(theme.panel.opacity(0.75)).padding(.top, 3)
                }
                .overlay(alignment: .bottomLeading) {
                    if let bottomLabel { scaleLabel(bottomLabel).padding(.bottom, 3) }
                }
                .overlay { readout }
                // With the axis at the bottom, its line runs just under the plot.
                .padding(.bottom, axis == .bottom ? 1 : 0)
                .accessibilityElement()
                .accessibilityLabel(description)
            HStack {
                Text("hace \(Self.duration(timeline.window))")
                Spacer()
                Text("ahora")
            }
            .font(.panelAxis)
            .lineBox(12)
            .foregroundStyle(theme.muted)
            .accessibilityHidden(true)
        }
    }

    private func scaleLabel(_ text: String) -> some View {
        Text(text).font(.panelScale).monospacedDigit().foregroundStyle(theme.muted)
    }

    /// Solid 1 px rules: the edges of the scale, and the axis the lines grow from.
    private var grid: some View {
        VStack(spacing: 0) {
            rule(theme.hairline)
            Spacer(minLength: 0)
            rule(axis == .middle ? theme.axis : theme.hairline)
            Spacer(minLength: 0)
            rule(axis == .middle ? theme.hairline : theme.axis)
        }
        .padding(.bottom, axis == .bottom ? -1 : 0)
    }

    private func rule(_ color: Color) -> some View {
        Rectangle().fill(color).frame(height: 1)
    }

    // MARK: Detailed

    private func detailed(_ detail: Detail) -> some View {
        VStack(spacing: 0) {
            plot(lineWidth: 1.5)
                .frame(height: height)
                .background { marks(detail) }
                .overlay { highlights(detail) }
                .overlay { readout }
                .accessibilityElement()
                .accessibilityLabel(description)
            timeMarks.frame(height: 18)
        }
        .padding(.trailing, Self.scaleWidth)
        .overlay(alignment: .topTrailing) {
            // Each value sits on its rule, 6 pt to the right of the plot.
            ZStack(alignment: .topLeading) {
                ForEach(detail.marks.indices, id: \.self) { index in
                    scaleLabel(detail.marks[index].label).lineBox(12).fixedSize()
                        .offset(y: height * (1 - detail.marks[index].level) - 6)
                }
            }
            .frame(width: Self.scaleWidth - 6, height: height, alignment: .topLeading)
            .accessibilityHidden(true)
        }
    }

    private func marks(_ detail: Detail) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(detail.marks.indices, id: \.self) { index in
                rule(detail.marks[index].isAxis ? theme.axis : theme.hairline)
                    .offset(y: height * (1 - detail.marks[index].level))
            }
            if let threshold = detail.threshold {
                let y = height * (1 - threshold.level)
                rule(Theme.warning.opacity(0.55)).offset(y: y)
                HStack(spacing: 4) {
                    Path { path in
                        path.move(to: CGPoint(x: 5, y: 0.5))
                        path.addLine(to: CGPoint(x: 9.6, y: 8.5))
                        path.addLine(to: CGPoint(x: 0.4, y: 8.5))
                        path.closeSubpath()
                    }
                    .fill(Theme.warning)
                    .frame(width: 10, height: 9)
                    scaleLabel(threshold.label)
                }
                .lineBox(12)
                .offset(y: y - 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The circled peak and a dot where each line ends, ringed with the panel colour so
    /// that they stand apart from the lines.
    private func highlights(_ detail: Detail) -> some View {
        GeometryReader { proxy in
            let positions = timeline.positions
            if positions.count > 1 {
                if let peak = detail.peak, traces.indices.contains(peak.trace) {
                    let trace = traces[peak.trace]
                    let sample = trace.levels.indices.max { trace.levels[$0] < trace.levels[$1] } ?? 0
                    let at = Self.point(trace, sample, positions, in: proxy.size)
                    Circle().fill(theme.panel).overlay(Circle().stroke(trace.color, lineWidth: 1.5))
                        .frame(width: 6, height: 6).position(at)
                    Text(peak.label(sample)).font(.panelScale).monospacedDigit().foregroundStyle(theme.secondary)
                        .fixedSize()
                        .position(x: min(proxy.size.width - 18, max(18, at.x)), y: (at.y >= detail.peakClearance ? at.y - 18 : at.y + 8) + 6)
                }
                ForEach(traces.indices, id: \.self) { index in
                    if detail.endDots, traces[index].isLine {
                        Circle().fill(traces[index].color).frame(width: 6, height: 6)
                            .padding(2).background(Circle().fill(theme.panel))
                            .position(Self.point(traces[index], positions.count - 1, positions, in: proxy.size))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static func point(_ trace: GraphTrace, _ sample: Int, _ positions: [Double], in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * positions[sample], y: size.height * (1 - min(1, max(0, trace.levels[sample]))))
    }

    /// Four equal steps back from now, each with a tick.
    private var timeMarks: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(0..<5, id: \.self) { step in
                    let x = proxy.size.width * CGFloat(step) / 4
                    // The whole span reads best in minutes; the steps inside it, in seconds.
                    let seconds = timeline.window * Double(4 - step) / 4
                    let label = step == 4 ? "ahora" : step == 0 ? "−\(Self.duration(seconds))" : "−\(Int(seconds.rounded())) s"
                    Rectangle().fill(theme.axis).frame(width: 1, height: 4).offset(x: x)
                    scaleLabel(label).lineBox(12)
                        .frame(width: 60, alignment: step == 0 ? .leading : step == 4 ? .trailing : .center)
                        .offset(x: x - (step == 0 ? 0 : step == 4 ? 60 : 30), y: 6)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Plot

    private func plot(lineWidth: CGFloat) -> some View {
        let positions = timeline.positions
        return ZStack {
            ForEach(traces.indices, id: \.self) { index in
                let trace = traces[index]
                if trace.fillOpacity > 0, style == .area {
                    TraceShape(positions: positions, levels: trace.levels, base: trace.base)
                        .fill(trace.color.opacity(trace.fillOpacity))
                } else if trace.fillOpacity > 0, style == .bars {
                    BarsShape(positions: positions, levels: trace.levels, base: trace.base).fill(trace.color)
                }
            }
            if style != .bars {
                ForEach(traces.indices, id: \.self) { index in
                    if traces[index].isLine {
                        TraceShape(positions: positions, levels: traces[index].levels, base: nil)
                            .stroke(traces[index].color,
                                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
    }

    // MARK: Readout

    private var readout: some View {
        GeometryReader { proxy in
            let positions = timeline.positions
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        hoveredSample = positions.indices.min {
                            abs(positions[$0] * proxy.size.width - location.x) < abs(positions[$1] * proxy.size.width - location.x)
                        }
                    case .ended:
                        hoveredSample = nil
                    }
                }
                if let sample = hoveredSample ?? pinnedSample, sample < positions.count {
                    let x = proxy.size.width * positions[sample]
                    Rectangle().fill(theme.muted).frame(width: 1).offset(x: x - 0.5)
                    ForEach(traces.indices, id: \.self) { index in
                        if traces[index].isLine {
                            // A 2 pt ring of the panel colour keeps the dot apart from the lines.
                            Circle().fill(traces[index].color).frame(width: 8, height: 8)
                                .padding(2).background(Circle().fill(theme.panel))
                                .position(Self.point(traces[index], sample, positions, in: proxy.size))
                        }
                    }
                    let leading = x < proxy.size.width / 2
                    tooltip(for: sample)
                        .padding(leading ? .leading : .trailing, leading ? x + 12 : proxy.size.width - x + 12)
                        .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func tooltip(for sample: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            let age = timeline.ages[sample]
            Text(age >= 0.5 ? "hace \(Self.duration(age))" : "ahora").foregroundStyle(theme.muted)
            ForEach(traces.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(traces[index].color).frame(width: 8, height: 8)
                    Text(traces[index].name).foregroundStyle(theme.secondary)
                    Text(traces[index].reading(sample)).monospacedDigit()
                }
            }
        }
        .font(.panelNote)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.outline))
    }

    /// "48 s", "2 min" or "1 min 30 s".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60, rest = total % 60
        if minutes == 0 { return "\(rest) s" }
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}

extension HistoryGraph {
    /// Two rates on one shared scale: `upper` grows up from the middle axis and `lower`
    /// grows down, so the two can be compared by eye.
    static func mirrored(timeline: MetricHistory, upper: (name: String, values: [Double]),
                         lower: (name: String, values: [Double]), scale: RateScale, detailed: Bool,
                         simpleHeight: CGFloat, theme: Theme, description: String) -> HistoryGraph {
        let height: CGFloat = detailed ? 100 : simpleHeight
        // Leaves room for the line width at the top and bottom edges.
        let reach = (height / 2 - 2) / height
        func trace(_ series: (name: String, values: [Double]), _ color: Color, _ opacity: Double,
                   direction: Double) -> GraphTrace {
            GraphTrace(name: series.name, color: color, fillOpacity: opacity,
                       levels: series.values.map { 0.5 + direction * min(1, $0 / scale.ceiling) * reach },
                       base: 0.5) { Format.rate(series.values[$0]) }
        }
        let shares: [(share: Double, direction: Double)] = [(1, 1), (0.5, 1), (0, 0), (0.5, -1), (1, -1)]
        let detail = Detail(marks: shares.map {
            Detail.Mark(level: 0.5 + $0.direction * $0.share * reach, label: scale.mark($0.share), isAxis: $0.share == 0)
        }, peak: (0, { scale.text(upper.values[$0]) }), peakClearance: 15)
        return HistoryGraph(height: height, axis: .middle, timeline: timeline,
                            traces: [trace(upper, theme.blue, theme.areaOpacity, direction: 1),
                                     trace(lower, theme.orange, theme.secondAreaOpacity, direction: -1)],
                            topLabel: scale.label, detail: detailed ? detail : nil, description: description)
    }
}

/// A round ceiling for a graph of rates, and the unit its values read best in.
struct RateScale {
    /// Bytes per second at the edge of the graph.
    let ceiling: Double
    let unit: String
    private let divisor: Double
    private let digits: Int

    private static let steps: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]

    /// The smallest round value at or above the peak, so that the scale reads cleanly
    /// and does not move with every sample.
    init(peak: Double, minimum: Double) {
        let value = max(peak, minimum)
        let magnitude = pow(10, floor(log10(value)))
        ceiling = (Self.steps.first { $0 * magnitude >= value } ?? 10) * magnitude
        let index = ceiling >= 1e9 ? 2 : ceiling >= 1e6 ? 1 : 0
        unit = ["KB/s", "MB/s", "GB/s"][index]
        divisor = [1e3, 1e6, 1e9][index]
        // Finer figures while the whole scale is only a few units.
        digits = index == 0 ? 0 : ceiling / divisor < 10 ? 2 : 1
    }

    /// The ceiling without padding zeros: "5 MB/s", "1,2 MB/s".
    var label: String {
        mark(1) + " " + unit
    }

    /// A share of the ceiling, as a bare number in the scale's unit.
    func mark(_ share: Double) -> String {
        let amount = (ceiling * share / divisor * 10).rounded() / 10
        return Format.number(amount, digits: amount == amount.rounded() ? 0 : 1)
    }

    /// A rate as a bare number in the scale's unit.
    func text(_ bytesPerSecond: Double) -> String {
        Format.number(bytesPerSecond / divisor, digits: digits)
    }
}

/// A small filled line with its axis, for a reading that sits in a row or a cell.
struct Sparkline: View {
    var timeline: MetricHistory
    /// 0...1, one per sample of the timeline.
    var levels: [Double]

    @Environment(\.theme) private var theme

    var body: some View {
        let positions = timeline.positions
        ZStack {
            TraceShape(positions: positions, levels: levels, base: Array(repeating: 0, count: levels.count))
                .fill(theme.blue.opacity(theme.areaOpacity))
            TraceShape(positions: positions, levels: levels, base: nil)
                .stroke(theme.blue, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .clipped()
        .padding(.bottom, 1)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.axis).frame(height: 1) }
        .accessibilityHidden(true)
    }
}

private struct TraceShape: Shape {
    /// 0...1 across the width, one per sample.
    var positions: [Double]
    var levels: [Double]
    /// With a base, the shape is the area between the line and it; without, the line alone.
    var base: [Double]?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard levels.count > 1, positions.count == levels.count else { return path }
        func point(_ index: Int, _ level: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * CGFloat(positions[index]),
                    y: rect.maxY - rect.height * CGFloat(min(1, max(0, level))))
        }
        path.move(to: point(0, levels[0]))
        for index in levels.indices.dropFirst() {
            path.addLine(to: point(index, levels[index]))
        }
        if let base {
            for index in base.indices.reversed() {
                path.addLine(to: point(index, base[index]))
            }
            path.closeSubpath()
        }
        return path
    }
}

/// One bar per sample, from the base to the level.
private struct BarsShape: Shape {
    var positions: [Double]
    var levels: [Double]
    var base: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard positions.count == levels.count, !levels.isEmpty else { return path }
        // As wide as the closest two samples allow, less a gap.
        let spacing = zip(positions.dropFirst(), positions).map { $0 - $1 }.filter { $0 > 0 }.min() ?? 1 / 60
        let width = max(1, (rect.width * CGFloat(spacing)).rounded(.down) - 1)
        for index in levels.indices {
            let level = min(1, max(0, levels[index])), base = min(1, max(0, base[index]))
            guard level != base else { continue }
            // Each bar ends where the line would pass, so the newest touches the right edge.
            path.addRect(CGRect(x: rect.minX + rect.width * CGFloat(positions[index]) - width,
                                y: rect.maxY - rect.height * CGFloat(max(level, base)),
                                width: width, height: rect.height * CGFloat(abs(level - base))))
        }
        return path
    }
}

private struct GraphStyleKey: EnvironmentKey {
    static let defaultValue = GraphStyle.area
}

extension EnvironmentValues {
    var graphStyle: GraphStyle {
        get { self[GraphStyleKey.self] }
        set { self[GraphStyleKey.self] = newValue }
    }
}
