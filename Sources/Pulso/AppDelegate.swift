import AppKit
import Combine
import PulsoCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var store: MetricsStore = {
        let store = MetricsStore(interval: settings.refreshInterval)
        store.ignoredCores = settings.ignoredCores
        store.recordsCores = settings.detail == .advanced
        return store
    }()
    private let fans = FanControlModel()
    private var statusBar: StatusBarController?
    private var settingsWindow: NSWindow?
    private var activity: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--render-snapshots"), flag + 1 < arguments.count {
            SnapshotRenderer.run(into: URL(fileURLWithPath: arguments[flag + 1]), store: store, settings: settings)
            return
        }
        // A second copy would just duplicate every item in the menu bar.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            NSApp.terminate(nil)
            return
        }

        // Pulso never has a visible window, which makes it a prime App Nap candidate;
        // napping would stall the timer and freeze the readouts.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Live menu bar readouts")
        statusBar = StatusBarController(store: store, settings: settings, fans: fans) { [weak self] in
            self?.showSettings()
        }
        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] in self?.store.setInterval($0) }
            .store(in: &cancellables)
        settings.$ignoredCores
            .dropFirst()
            .sink { [weak self] in self?.store.ignoredCores = $0 }
            .store(in: &cancellables)
        settings.$detail
            .dropFirst()
            .sink { [weak self] in self?.store.recordsCores = $0 == .advanced }
            .store(in: &cancellables)
        store.start()
        fans.refresh()
        pauseWhileUnseen()

        // `Pulso --open-panel cpu` opens a panel once its item has settled, to check
        // the real window on screen without a pointer.
        if let flag = arguments.firstIndex(of: "--open-panel"), flag + 1 < arguments.count,
           let kind = ModuleKind(rawValue: arguments[flag + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.statusBar?.openPanel(for: kind)
            }
        }
    }

    /// Launching Pulso again while it is running (e.g. from Spotlight) opens its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Fans set by hand go back to the system when Pulso quits.
    func applicationWillTerminate(_ notification: Notification) {
        fans.releaseAndWait()
        store.shutDown()
    }

    /// Nothing is measured while nothing can be seen: with the displays asleep, the session
    /// locked or another user at the screen.
    private func pauseWhileUnseen() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let changes: [(NotificationCenter, Notification.Name, Bool)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, true),
            (workspace, NSWorkspace.screensDidWakeNotification, false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), false),
        ]
        for (center, name, paused) in changes {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.store.setPaused(paused) }
                .store(in: &cancellables)
        }
    }

    /// The modules this machine has no hardware for.
    static func unavailableModules(in snapshot: SystemSnapshot) -> Set<ModuleKind> {
        var modules: Set<ModuleKind> = []
        if snapshot.battery == nil { modules.insert(.battery) }
        if snapshot.gpus.first?.utilization == nil { modules.insert(.gpu) }
        return modules
    }

    private func showSettings() {
        statusBar?.closePanels()
        if settingsWindow == nil {
            let unavailable = store.snapshot.map(Self.unavailableModules) ?? []
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: settings, unavailableModules: unavailable)))
            window.title = "Ajustes de Pulso"
            window.styleMask = [.titled, .closable]
            // The title bar is part of the same surface as the content, set apart by a rule.
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .line
            window.backgroundColor = .panelSurface
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // An accessory app is never frontmost on its own, so its windows open behind everything.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
