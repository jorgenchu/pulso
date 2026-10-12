import AppKit
import SwiftUI

/// A borderless window that hangs under a status item. A panel rather than an
/// `NSPopover` so its shape, surface and placement are fully ours to design.
final class DropdownPanel: NSPanel {
    var onCancel: (() -> Void)?

    private let hostingView: NSView

    init(rootView: some View) {
        let hostingView = NSHostingView(rootView: rootView)
        self.hostingView = hostingView
        // Non-activating: opening a panel must not steal focus from the app in use.
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        // The SwiftUI content draws the panel surface itself, rounded corners included,
        // and the window shadow follows whatever is opaque.
        let container = NSView()
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    /// The size the SwiftUI content wants.
    var fittingContentSize: NSSize {
        hostingView.fittingSize
    }

    // Borderless windows refuse key status by default; the panel needs it for Esc.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Places the panel just below `anchor` (in screen coordinates), centred on it and
    /// kept inside the screen. Keeps the top edge fixed when the content changes height.
    func position(below anchor: NSRect, on screen: NSScreen?) {
        let size = fittingContentSize
        var x = anchor.midX - size.width / 2
        var top = anchor.minY
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            // Beside a notch the menu bar is taller than its items; hang from the bar.
            top = min(top, visible.maxY)
        }
        let frame = NSRect(x: round(x), y: round(top - size.height - Self.gap), width: size.width, height: size.height)
        if frame != self.frame {
            setFrame(frame, display: true)
            invalidateShadow()
        }
    }

    /// Space between the menu bar and the panel.
    private static let gap: CGFloat = 8
}
