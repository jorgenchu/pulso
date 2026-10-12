import AppKit

@main
enum PulsoApp {
    @MainActor
    static func main() {
        let delegate = AppDelegate()
        let application = NSApplication.shared
        application.delegate = delegate
        // Menu bar only: no Dock icon and no app menu.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
