import AppKit
import Combine
import PulsoCore
import SwiftUI

/// Renders the menu bar items, every panel and the settings to PNG files, with live data
/// and in both appearances, and exits. Run with `Pulso --render-snapshots <directory>` to
/// review the UI without screen recording permission, and to compare it against the design:
/// each image is composed the way its design board is.
@MainActor
enum SnapshotRenderer {
    private static var subscription: AnyCancellable?

    static func run(into directory: URL, store: MetricsStore, settings: AppSettings) {
        store.setProcessListVisible(true)
        store.setNetworkProcessListVisible(true)
        // Sampling twice a second and dating the samples a second apart fills the two
        // minutes the panels look back on in one. `--samples` cuts it shorter.
        store.historyStep = MetricsStore.panelInterval
        store.recordsCores = true
        store.setInterval(0.5)
        store.start()
        let arguments = CommandLine.arguments
        let wanted = arguments.firstIndex(of: "--samples").flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil }
            ?? Int(MetricHistory.span / MetricsStore.panelInterval)
        var samples = 0
        subscription = store.$snapshot.compactMap { $0 }.sink { snapshot in
            samples += 1
            guard samples == wanted else { return }
            DispatchQueue.main.async {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    do {
                        // The panels read the level of detail from the settings; put back
                        // what was there before leaving, since `exit` skips everything after it.
                        let detail = settings.detail
                        defer { settings.detail = detail }
                        for scheme in [ColorScheme.dark, .light] {
                            try render(snapshot, store: store, settings: settings, scheme: scheme, into: directory)
                        }
                    }
                    store.shutDown()
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                    store.shutDown()
                    exit(1)
                }
            }
        }
    }

    private static func render(_ snapshot: SystemSnapshot, store: MetricsStore, settings: AppSettings,
                               scheme: ColorScheme, into directory: URL) throws {
        let backdrop = Backdrop(scheme)
        func file(_ name: String) -> URL {
            directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
        }

        var items: [ModuleKind: NSImage] = [:]
        for kind in ModuleKind.allCases {
            items[kind] = MenuBarContent.make(for: kind, snapshot: snapshot, history: store.history, settings: settings)
                .map(MenuBarRenderer.image)
        }
        let strip = menuBar(ModuleKind.allCases.compactMap { items[$0] }, on: backdrop)
        try write(strip, to: file("menubar"))
        try write(strip, to: file("menubar-zoom"), scale: 8)

        let fans = FanControlModel()
        for detail in PanelDetail.allCases {
            settings.detail = detail
            // The battery panel is the same at both levels.
            for kind in ModuleKind.allCases where detail == .simple || kind != .battery {
                let panel = ModulePanel(kind: kind, store: store, settings: settings, fans: fans)
                    .compositingGroup()
                    .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.22), radius: 24, y: 18)
                    .padding(EdgeInsets(top: 8, leading: 40, bottom: 72, trailing: 40))
                if let image = rendered(panel, scheme: scheme) {
                    try write(board(item: items[kind], panel: image, on: backdrop),
                              to: file("panel-\(kind.rawValue)\(detail == .advanced ? "-advanced" : "")"))
                }
            }
        }
        let unavailable = AppDelegate.unavailableModules(in: snapshot)
        for page in SettingsView(settings: settings, unavailableModules: unavailable).pages() {
            let view = SettingsView(settings: settings, unavailableModules: unavailable, page: page)
            guard let image = rendered(view, scheme: scheme) else { continue }
            if case let .module(kind) = page {
                try write(image, to: file("settings-\(kind.rawValue)"))
            } else {
                try write(image, to: file("settings"))
            }
        }
        if let image = rendered(ComponentSheet().padding(40).background(backdrop.desktop), scheme: scheme) {
            try write(image, to: file("components"))
        }
    }

    private static func rendered(_ view: some View, scheme: ColorScheme) -> NSImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        return renderer.nsImage
    }

    /// Lays the template images out on a strip, tinted the way the menu bar tints them.
    private static func menuBar(_ images: [NSImage], on backdrop: Backdrop) -> NSImage {
        let spacing: CGFloat = 18, padding: CGFloat = 16
        let width = images.reduce(padding * 2 - spacing) { $0 + $1.size.width + spacing }
        return NSImage(size: NSSize(width: width, height: Backdrop.barHeight), flipped: false) { rect in
            NSColor(backdrop.bar).setFill()
            rect.fill()
            var x = padding
            for image in images {
                tinted(image, with: NSColor(backdrop.barText))
                    .draw(in: NSRect(x: x, y: (rect.height - image.size.height) / 2, width: image.size.width, height: image.size.height))
                x += image.size.width + spacing
            }
            return true
        }
    }

    /// A panel under its highlighted menu bar item, on the desktop.
    private static func board(item: NSImage?, panel: NSImage, on backdrop: Backdrop) -> NSImage {
        let size = NSSize(width: panel.size.width, height: Backdrop.barHeight + panel.size.height)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(backdrop.desktop).setFill()
            rect.fill()
            NSColor(backdrop.bar).setFill()
            NSRect(x: 0, y: rect.maxY - Backdrop.barHeight, width: rect.width, height: Backdrop.barHeight).fill()
            if let item {
                let frame = NSRect(x: (rect.width - item.size.width) / 2,
                                   y: rect.maxY - (Backdrop.barHeight + item.size.height) / 2,
                                   width: item.size.width, height: item.size.height)
                NSColor(backdrop.highlight).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: -8, dy: 0), xRadius: 6, yRadius: 6).fill()
                tinted(item, with: NSColor(backdrop.barText)).draw(in: frame)
            }
            panel.draw(in: NSRect(origin: .zero, size: panel.size))
            return true
        }
    }

    /// Recolours a template image, keeping its alpha, as the menu bar does. This has to
    /// happen on a transparent canvas of its own: over the opaque strip, `sourceAtop`
    /// would paint the whole rectangle.
    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func write(_ image: NSImage, to url: URL, scale: CGFloat = 2) throws {
        let pixels = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // A bitmap context works in pixels, so the image is drawn across the full pixel rect.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = image.size
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}

/// What the design boards put around the app: a desktop and a menu bar.
private struct Backdrop {
    static let barHeight: CGFloat = 30

    let desktop: Color
    let bar: Color
    let barText: Color
    /// Behind the item whose panel is open.
    let highlight: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            desktop = Color(hex: 0x0E0F10)
            bar = Color(hex: 0x2A2D31)
            barText = Theme.dark.text
            highlight = .white.opacity(0.16)
        } else {
            desktop = Color(hex: 0xD9DDE1)
            bar = Color(hex: 0xEEEEEC)
            barText = Theme.light.text
            highlight = .black.opacity(0.10)
        }
    }
}

/// The components that live data rarely or never shows: the meter away from normal and
/// the graph readout, laid out as on the Fundamentos board and with its sample values.
private struct ComponentSheet: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            card("Medidor y sus estados", spacing: 14) {
                MeterRow(label: "CPU · rendimiento", value: "58°", fraction: 0.42)
                MeterRow(label: "CPU · rendimiento", value: "92°", fraction: 0.80, level: .warning)
                MeterRow(label: "CPU · rendimiento", value: "104°", fraction: 0.93, level: .critical)
                HStack(spacing: 16) {
                    ForEach([Level.normal, .warning, .critical], id: \.self) { StatusBadge(level: $0) }
                }
                .font(.panelRow)
            }
            card("Gráfica con lectura al pasar el cursor", spacing: 10) {
                let user = Self.walk(seed: 23, base: 0.26, swing: 0.2, range: 0.08...0.66)
                let system = Self.walk(seed: 7, base: 0.08, swing: 0.05, range: 0.03...0.16)
                // One sample every two seconds, as the boards assume.
                let history = MetricHistory(samples: user.indices.map {
                    MetricSample(time: Double($0) * 2, cpuUser: user[$0], cpuSystem: system[$0])
                })
                CPUPanel.usageGraph(timeline: history, theme: theme, pinnedSample: 36)
            }
            card("Ventilador en manual", spacing: 5) {
                // The engine only builds fan states from what the helper reports; decode one.
                let sample = #"{"index":0,"mode":"manual","rpm":2584,"targetRPM":2600,"limits":{"minimum":1499,"maximum":4296}}"#
                if let fan = try? JSONDecoder().decode(FanState.self, from: Data(sample.utf8)) {
                    FanSlider(fan: fan, rpm: fan.rpm) { _ in }
                }
            }
            card("Barra apilada", spacing: 10) {
                StackedBar(segments: [(54, theme.blue), (26, theme.orange), (18, theme.aqua), (39, theme.yellow), (23, theme.idle)])
            }
        }
    }

    private func card(_ title: String, spacing: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: spacing) {
            SectionTitle(title)
            content()
        }
        .padding(Metrics.margin)
        .frame(width: Metrics.panelWidth, alignment: .leading)
        .foregroundStyle(theme.text)
        .background(shape.fill(theme.panel))
        .overlay(shape.strokeBorder(theme.outline))
    }

    /// The boards' sample data: a bounded random walk that drifts back to its base.
    private static func walk(seed: Int, base: Double, swing: Double, range: ClosedRange<Double>) -> [Double] {
        var state = seed, value = base
        return (0..<60).map { _ in
            state = state * 16807 % 2_147_483_647
            value += (Double(state) / 2_147_483_647 - 0.5) * swing + (base - value) * 0.1
            value = min(range.upperBound, max(range.lowerBound, value))
            return value
        }
    }
}
