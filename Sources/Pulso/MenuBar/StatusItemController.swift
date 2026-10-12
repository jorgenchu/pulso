import AppKit
import PulsoCore

/// One menu bar item and the panel that drops down from it.
@MainActor
final class StatusItemController: NSObject {
    let kind: ModuleKind
    var onOpenSettings: (() -> Void)?

    private let store: MetricsStore
    private let settings: AppSettings
    private let fans: FanControlModel
    private let statusItem: NSStatusItem
    private var content: MenuBarContent?
    private var panel: DropdownPanel?
    /// Whether the open panel turned process sampling on, and so has to turn it off.
    private var listsProcesses = false
    private var listsTraffic = false
    private var eventMonitors: [Any] = []

    init(kind: ModuleKind, store: MetricsStore, settings: AppSettings, fans: FanControlModel) {
        self.kind = kind
        self.store = store
        self.settings = settings
        self.fans = fans
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Lets the system remember where the user dragged the item.
        statusItem.autosaveName = "pulso.\(kind.rawValue)"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(kind.title)
            button.image = MenuBarRenderer.image(for: .placeholder(for: kind))
        }
    }

    func remove() {
        closePanel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// `redrawsItem` is false for the samples that only an open panel needs.
    func update(_ snapshot: SystemSnapshot, history: MetricHistory, redrawsItem: Bool) {
        // The panel's SwiftUI content re-renders after this call returns, so measure it on the next turn.
        if panel != nil {
            DispatchQueue.main.async { [weak self] in self?.positionPanel() }
        }
        guard redrawsItem else { return }
        let content = MenuBarContent.make(for: kind, snapshot: snapshot, history: history, settings: settings)
        // Every change to a status item makes AppKit re-capture it for the menu bar of
        // each other display, which costs far more than producing the content. So touch
        // the item only when what it shows actually changed.
        if statusItem.isVisible != (content != nil) {
            // Nothing to show on this machine (e.g. the battery module on a desktop).
            statusItem.isVisible = content != nil
        }
        if let content, content != self.content {
            statusItem.button?.image = MenuBarRenderer.image(for: content)
            statusItem.button?.setAccessibilityValue(Self.spokenText(for: content))
        }
        self.content = content
    }

    private static func spokenText(for content: MenuBarContent) -> String {
        switch content {
        case let .value(_, _, text, _): return text
        case let .stacked(top, bottom, _): return "\(top), \(bottom)"
        }
    }

    // MARK: Panel

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseDown {
            showMenu()
        } else if panel == nil {
            openPanel()
        } else {
            closePanel()
        }
    }

    func openPanel() {
        guard panel == nil else { return }
        let view = ModulePanel(kind: kind, store: store, settings: settings, fans: fans,
                               onOpenSettings: { [weak self] in
                                   self?.closePanel()
                                   self?.onOpenSettings?()
                               },
                               onQuit: { NSApp.terminate(nil) })
        let panel = DropdownPanel(rootView: view)
        panel.onCancel = { [weak self] in self?.closePanel() }
        self.panel = panel
        positionPanel()
        panel.orderFrontRegardless()
        panel.makeKey()

        // Mouse tracking clears the highlight when the click ends, so set it afterwards.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel != nil else { return }
            self.statusItem.button?.highlight(true)
        }
        // An open panel refreshes every second, and samples what only it shows.
        store.setPanelOpen(true)
        listsProcesses = settings.listsProcesses(in: kind)
        if listsProcesses { store.setProcessListVisible(true) }
        listsTraffic = kind == .network && settings.shows(.networkProcesses)
        if listsTraffic { store.setNetworkProcessListVisible(true) }
        installEventMonitors()
    }

    func closePanel() {
        guard let panel else { return }
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        panel.close()
        self.panel = nil
        statusItem.button?.highlight(false)
        store.setPanelOpen(false)
        if listsProcesses { store.setProcessListVisible(false) }
        if listsTraffic { store.setNetworkProcessListVisible(false) }
    }

    private func positionPanel() {
        guard let panel, let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.position(below: anchor, on: window.screen)
    }

    /// Any click outside the panel dismisses it. Clicks in other apps only reach the
    /// global monitor; clicks in Pulso's own windows only reach the local one.
    private func installEventMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // A click on our own button is left to `handleClick`, which toggles.
                if event.window !== panel, event.window !== self.statusItem.button?.window {
                    self.closePanel()
                }
            }
            return event
        }
        eventMonitors = [global, local].compactMap { $0 }
    }

    // MARK: Context menu

    private func showMenu() {
        closePanel()
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Ajustes de Pulso…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let quitItem = NSMenuItem(title: "Salir de Pulso", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.items = [settingsItem, .separator(), quitItem]

        // Attaching the menu only for this click keeps left clicks free for the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
