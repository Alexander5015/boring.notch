// Live probe: can a normal (unprivileged) app elevate FOREIGN windows — e.g. the
// Dock-hosted macOS desktop widgets — into a SkyLight space at the lock-screen
// level, the way tools manipulate notification banners?
//
// Read-only toward the system: the only mutation attempted is against windows
// this probe owns or spawns (a helper child process). No user window is touched.
//
// Run stages from inside a live NSApplication: a bare command-line process has
// no WindowServer app connection, which is the suspected cause of CGError 3.
//
// Usage: swiftc LockScreenWidgetProbe.swift -o lock-probe && ./lock-probe ./helper-window

import AppKit
import CoreGraphics
import Foundation

// MARK: - SLS shims (same symbols SkyLightWindow binds)

let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)

typealias F_SLSMainConnectionID = @convention(c) () -> Int32
typealias F_SLSSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
typealias F_SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
typealias F_SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
typealias F_SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
typealias F_SLSSpaceRemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32
typealias F_SLSAddWindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
typealias F_SLSCopyManagedDisplaySpaces = @convention(c) (Int32) -> CFArray

let SLSMainConnectionID = unsafeBitCast(dlsym(skylight, "SLSMainConnectionID"), to: F_SLSMainConnectionID.self)
let SLSSpaceCreate = unsafeBitCast(dlsym(skylight, "SLSSpaceCreate"), to: F_SLSSpaceCreate.self)
let SLSSpaceSetAbsoluteLevel = unsafeBitCast(dlsym(skylight, "SLSSpaceSetAbsoluteLevel"), to: F_SLSSpaceSetAbsoluteLevel.self)
let SLSShowSpaces = unsafeBitCast(dlsym(skylight, "SLSShowSpaces"), to: F_SLSShowSpaces.self)
let SLSSpaceAddWindowsAndRemoveFromSpaces = unsafeBitCast(dlsym(skylight, "SLSSpaceAddWindowsAndRemoveFromSpaces"), to: F_SLSSpaceAddWindowsAndRemoveFromSpaces.self)
let SLSRemoveWindowsFromSpaces = unsafeBitCast(dlsym(skylight, "SLSRemoveWindowsFromSpaces"), to: F_SLSSpaceRemoveWindows.self)
let SLSAddWindowsToSpaces = unsafeBitCast(dlsym(skylight, "SLSAddWindowsToSpaces"), to: F_SLSAddWindowsToSpaces.self)
let SLSCopyManagedDisplaySpaces = unsafeBitCast(dlsym(skylight, "SLSCopyManagedDisplaySpaces"), to: F_SLSCopyManagedDisplaySpaces.self)

func stage(_ message: String) {
    print("STAGE: \(message)")
    fflush(stdout)
}

func cgErrorName(_ code: Int32) -> String {
    switch code {
    case 0: return "success"
    case 1: return "kCGErrorFailure"
    case 2: return "kCGErrorIllegalArgument"
    case 3: return "kCGErrorInvalidConnection"
    case 4: return "kCGErrorInvalidContext"
    case 5: return "kCGErrorCannotComplete"
    case 1001: return "kCGErrorInvalidConnection(1001)"
    default: return "code \(code)"
    }
}

func isOnScreen(_ windowNumber: Int) -> Bool {
    let nowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return nowInfo.contains {
        ($0[kCGWindowNumber as String] as? Int) == windowNumber
            && ($0[kCGWindowIsOnscreen as String] as? Bool == true)
    }
}

let cid = SLSMainConnectionID()

// MARK: - Desktop widget discovery (CGWindowList only)

func reportDesktopWidgets() {
    let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    print("\n=== Desktop widget candidates ===")
    fflush(stdout)
    var found = false
    for w in info {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let name = w[kCGWindowName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? -9999
        let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
        let ownerIsWidgetish = owner == "Dock" || owner.lowercased().contains("widget")
        guard ownerIsWidgetish, layer == 0 else { continue }
        let bounds = w[kCGWindowBounds as String] as? [String: CGFloat]
        let w0 = bounds?["Width"] ?? 0, h0 = bounds?["Height"] ?? 0
        guard w0 > 40, h0 > 40 else { continue }
        print("  win=\(w[kCGWindowNumber as String] ?? -1) owner=\(owner) name=\(name.isEmpty ? "(none)" : name) onscreen=\(onscreen) size=\(Int(w0))x\(Int(h0))")
        found = true
    }
    if !found {
        print("  (no desktop widgets detected on this Mac — flip on some widgets in\n   System Settings > Desktop & Dock > Widgets and rerun to enumerate them)")
    }
    fflush(stdout)
}

// MARK: - Space tests (run from inside the live NSApplication)

func runSpaceTests() {
    stage("cid=\(cid), app connection active")

    let os = ProcessInfo.processInfo.operatingSystemVersion
    stage("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)  AXtrusted=\(AXIsProcessTrusted())  screenCapture=\(CGPreflightScreenCaptureAccess())")

    // --- Control A: our OWN plain window ---
    let controlWindow = NSWindow(
        contentRect: NSRect(x: 140, y: 40, width: 80, height: 80),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    controlWindow.isOpaque = false
    controlWindow.backgroundColor = .clear
    controlWindow.level = .floating
    controlWindow.orderFrontRegardless()
    let controlWin = UInt32(controlWindow.windowNumber)
    stage("control window \(controlWin) (own NSWindow)")

    // Try BOTH connection IDs: SkyLightWindow uses SLSMainConnectionID() (nonzero),
    // while yabai-style tools historically use CGSMainConnectionID() == 0.
    // Call-shape variants on our own window, all on the SLS connection:
    let spaceOwn = SLSSpaceCreate(cid, 1, 0)
    let lvlOwn = SLSSpaceSetAbsoluteLevel(cid, spaceOwn, 400)
    _ = SLSShowSpaces(cid, [spaceOwn] as CFArray)
    stage("own space \(spaceOwn) created, setAbsoluteLevel(400) -> \(lvlOwn == 0 ? "ok" : cgErrorName(lvlOwn))")

    let displays = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? []
    stage("managed display spaces visible from this connection: \(displays.count)")

    let addOwn7 = SLSSpaceAddWindowsAndRemoveFromSpaces(cid, spaceOwn, [controlWin] as CFArray, 7)
    stage("variant A: AddWindowsAndRemoveFromSpaces(options=7) -> \(addOwn7 == 0 ? "SUCCESS" : "err \(cgErrorName(addOwn7))")")
    if addOwn7 != 0 {
        let addOwn0 = SLSSpaceAddWindowsAndRemoveFromSpaces(cid, spaceOwn, [controlWin] as CFArray, 0)
        stage("variant B: AddWindowsAndRemoveFromSpaces(options=0) -> \(addOwn0 == 0 ? "SUCCESS" : "err \(cgErrorName(addOwn0))")")
    }
    let addOwnList = SLSAddWindowsToSpaces(cid, [controlWin] as CFArray, [spaceOwn] as CFArray)
    stage("variant C: SLSAddWindowsToSpaces -> \(addOwnList == 0 ? "SUCCESS" : "err \(cgErrorName(addOwnList))")")
    if addOwnList == 0 || addOwn7 == 0 || addOwnList == 0 {
        Thread.sleep(forTimeInterval: 0.4)
        stage("own window still on-screen after re-spacing: \(isOnScreen(Int(controlWin)))")
        let backOwn = SLSRemoveWindowsFromSpaces(cid, [controlWin] as CFArray, [spaceOwn] as CFArray)
        stage("own window restored -> \(backOwn == 0 ? "ok" : cgErrorName(backOwn))")
    }

    // --- Control B: LockScreenWidgetPanel replica (shielding-level NSPanel) ---
    let panel = NSPanel(
        contentRect: NSRect(x: 240, y: 40, width: 80, height: 80),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.isFloatingPanel = true
    panel.canBecomeVisibleWithoutLogin = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    panel.orderFrontRegardless()
    let panelWin = UInt32(panel.windowNumber)
    Thread.sleep(forTimeInterval: 0.2)
    stage("panel window \(panelWin) (shielding level \(panel.level.rawValue))")

    let spacePanel = SLSSpaceCreate(cid, 1, 0)
    _ = SLSSpaceSetAbsoluteLevel(cid, spacePanel, 400)
    _ = SLSShowSpaces(cid, [spacePanel] as CFArray)
    let addPanel = SLSSpaceAddWindowsAndRemoveFromSpaces(cid, spacePanel, [panelWin] as CFArray, 7)
    stage("AddWindowsAndRemoveFromSpaces(OWN shielding panel) -> \(addPanel == 0 ? "SUCCESS" : "err \(cgErrorName(addPanel))")")
    if addPanel == 0 {
        Thread.sleep(forTimeInterval: 0.4)
        stage("panel still on-screen after re-spacing: \(isOnScreen(Int(panelWin)))")
        let backPanel = SLSRemoveWindowsFromSpaces(cid, [panelWin] as CFArray, [spacePanel] as CFArray)
        stage("panel restored -> \(backPanel == 0 ? "ok" : cgErrorName(backPanel))")
    }

    // --- Foreign window: helper child process ---
    let helperPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./helper-window"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: helperPath)
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    do { try proc.run() } catch {
        print("FATAL: could not spawn helper: \(error)")
        fflush(stdout)
        exit(1)
    }

    let initData = outPipe.fileHandleForReading.availableData
    guard let line = String(data: initData, encoding: .utf8)?.split(separator: "\n").first,
          let marker = line.range(of: "WINDOW_NUMBER="),
          let helperWin = UInt32(line[marker.upperBound...]) else {
        print("FATAL: helper did not report a window number")
        fflush(stdout)
        proc.terminate()
        exit(1)
    }
    stage("helper window \(helperWin) pid \(proc.processIdentifier) (foreign process)")

    let spaceForeign = SLSSpaceCreate(cid, 1, 0)
    _ = SLSSpaceSetAbsoluteLevel(cid, spaceForeign, 400)
    _ = SLSShowSpaces(cid, [spaceForeign] as CFArray)

    let addForeign = SLSSpaceAddWindowsAndRemoveFromSpaces(cid, spaceForeign, [helperWin] as CFArray, 7)
    stage("AddWindowsAndRemoveFromSpaces(FOREIGN window) -> \(addForeign == 0 ? "SUCCESS" : "err \(cgErrorName(addForeign))")")
    if addForeign == 0 {
        Thread.sleep(forTimeInterval: 0.4)
        stage("foreign window still on-screen after re-spacing: \(isOnScreen(Int(helperWin)))")
        let backForeign = SLSRemoveWindowsFromSpaces(cid, [helperWin] as CFArray, [spaceForeign] as CFArray)
        stage("foreign window restored -> \(backForeign == 0 ? "ok" : cgErrorName(backForeign))")
    }

    proc.terminate()
    print("\nProbe complete.")
    fflush(stdout)
    exit(0)
}

// MARK: - App lifecycle

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        reportDesktopWidgets()
        // Give the window server a beat to fully register the app connection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            runSpaceTests()
        }
    }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
