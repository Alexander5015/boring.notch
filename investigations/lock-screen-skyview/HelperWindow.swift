// Throwaway helper: shows one tiny borderless window, prints its windowNumber,
// then idles until killed. Exists only so the probe can test whether WindowServer
// permits space manipulation of a window owned by a DIFFERENT process.
import AppKit

let app = NSApplication.shared
let window = NSWindow(
    contentRect: NSRect(x: 40, y: 40, width: 80, height: 80),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.isOpaque = false
window.backgroundColor = .clear
window.level = .floating
window.orderFrontRegardless()
print("WINDOW_NUMBER=\(window.windowNumber)")
fflush(stdout)

let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
app.run()
