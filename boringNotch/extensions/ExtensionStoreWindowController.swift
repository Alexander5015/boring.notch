
import AppKit
import SwiftUI

final class ExtensionStoreWindowController: NSWindowController {
    static let shared = ExtensionStoreWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        super.init(window: window)

        window.title = "Boring Notch Extensions"
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.contentView = NSHostingView(rootView: ExtensionStoreView())
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow_() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}