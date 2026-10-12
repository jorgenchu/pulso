import AppKit
import Combine
import PulsoCore

/// Keeps one status item per enabled module and feeds them every new sample.
@MainActor
final class StatusBarController {
    private let store: MetricsStore
    private let settings: AppSettings
    private let fans: FanControlModel
    private let onOpenSettings: () -> Void
    private var items: [ModuleKind: StatusItemController] = [:]
    /// When the items were last redrawn, on the system's uptime clock.
    private var lastRedraw: TimeInterval = -.infinity
    private var cancellables: Set<AnyCancellable> = []

    init(store: MetricsStore, settings: AppSettings, fans: FanControlModel, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.fans = fans
        self.onOpenSettings = onOpenSettings

        settings.$enabledModules
            .sink { [weak self] in self?.sync(enabled: $0) }
            .store(in: &cancellables)
        store.$snapshot
            .compactMap { $0 }
            .sink { [weak self] in self?.update($0) }
            .store(in: &cancellables)
        // Any option can change what an item shows. The settings announce a change
        // before storing the new value, so redraw on the next turn.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.redraw() }
            .store(in: &cancellables)
    }

    func closePanels() {
        items.values.forEach { $0.closePanel() }
    }

    func openPanel(for kind: ModuleKind) {
        items[kind]?.openPanel()
    }

    private func sync(enabled: Set<ModuleKind>) {
        for (kind, item) in items where !enabled.contains(kind) {
            item.remove()
            items[kind] = nil
        }
        // The status bar places each new item to the left of the previous ones, so
        // creating them back to front leaves them in declaration order.
        for kind in ModuleKind.allCases.reversed() where enabled.contains(kind) && items[kind] == nil {
            let item = StatusItemController(kind: kind, store: store, settings: settings, fans: fans)
            item.onOpenSettings = onOpenSettings
            items[kind] = item
        }
        redraw()
    }

    /// With a panel open the samples come every second, but each redraw of an item costs
    /// a recapture per display, so the items still change at the menu bar's own pace.
    private func update(_ snapshot: SystemSnapshot, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        // A little slack, so a sample that arrives a moment early is not skipped.
        let redraws = force || now - lastRedraw >= store.barInterval - 0.25
        if redraws { lastRedraw = now }
        items.values.forEach { $0.update(snapshot, history: store.history, redrawsItem: redraws) }
    }

    private func redraw() {
        if let snapshot = store.snapshot { update(snapshot, force: true) }
    }
}
