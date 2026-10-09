//
//  BoringViewCoordinator.swift
//  boringNotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
}

struct SneakPeekState {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
    var accent: Color?
    var targetScreenUUID: String?
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
final class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()

    @Published var currentView: NotchViews = .home
    @Published var helloAnimationRunning: Bool = false
    private var osdEnableTask: Task<Void, Never>?
    private var osdLifecycleGeneration: UInt64 = 0
    private var isMediaKeyInterceptorRequested = false
    private var isBrightnessManagerObserving = false
    private var isVolumeManagerObserving = false
    private var isBetterDisplayObserving = false
    private var isLunarListening = false
    private var isLunarOSDHidden = false
    private var lastOSDBrightnessSource: OSDControlSource?
    private var lastOSDVolumeSource: OSDControlSource?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }

    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?

    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var osdReplacementCancellable: AnyCancellable?
    private var boringShelfCancellable: AnyCancellable?
    private var osdSourceCancellables: [AnyCancellable] = []
    private var notificationLiveActivityCancellable: AnyCancellable?
    private var uiEventCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }

        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if authorized {
                    // Authorization may have changed after the event tap stopped itself.
                    // Force one reconciliation attempt instead of trusting the previous flag.
                    self?.isMediaKeyInterceptorRequested = false
                    self?.applyOSDSources()
                    if Defaults[.notificationLiveActivity] {
                        await SystemNotificationManager.shared.start()
                    }
                } else {
                    self?.stopMediaKeyInterception()
                    SystemNotificationManager.shared.stop()
                }
            }
        }

        XPCHelperClient.shared.startMonitoringAccessibilityAuthorization()

        // Managers publish presentation events through the bus instead of
        // calling into the coordinator directly; the coordinator is the
        // single presenter (and keeps all show/hide policy in one place).
        uiEventCancellable = NotchUIEventBus.events
            .sink { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .sneakPeek(let type, let value, let icon, let accent, let uuid, let duration):
                        self.toggleSneakPeek(
                            status: true, type: type, duration: duration, value: value,
                            icon: icon, accent: accent, targetScreenUUID: uuid)
                    case .expandingView(let type):
                        self.toggleExpandingView(status: true, type: type)
                    }
                }
            }

        // Observe changes to osdReplacement
        osdReplacementCancellable = Defaults.publisher(.osdReplacement)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyOSDSources()
                }
            }
        // Observe changes to any of the OSD source selections
        osdSourceCancellables = [
            Defaults.publisher(.osdBrightnessSource).sink { [weak self] _ in Task { @MainActor in self?.applyOSDSources() } },
            Defaults.publisher(.osdVolumeSource).sink { [weak self] _ in Task { @MainActor in self?.applyOSDSources() } }
        ]
        boringShelfCancellable = Defaults.publisher(.boringShelf)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }
                    if !change.newValue && self.currentView == .shelf {
                        self.currentView = .home
                    }
                }
            }

        // Observe changes to the notification live activity toggle; it owns
        // the notification watcher lifecycle.
        notificationLiveActivityCancellable = Defaults.publisher(.notificationLiveActivity)
            .sink { change in
                Task { @MainActor in
                    if change.newValue {
                        await SystemNotificationManager.shared.start()
                    } else {
                        SystemNotificationManager.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch

            if Defaults[.notificationLiveActivity] {
                await SystemNotificationManager.shared.start()
            }
            self.applyOSDSources()
        }
    }

    // MARK: - Per-Screen Sneak Peek Management

    // Dictionary to hold sneak peek state for each screen UUID
    @Published var sneakPeekStates: [String: SneakPeekState] = [:]

    // Dictionary to hold hide tasks for each screen UUID
    private var sneakPeekTasks: [String: Task<Void, Never>] = [:]

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = "", accent: Color? = nil, targetScreenUUID: String? = nil
    ) {
        if type != .music {
            // close()
            if !Defaults[.osdReplacement] {
                return
            }
        }

        Task { @MainActor in
            // Helper to update state for a specific UUID
            @MainActor
            func updateState(for uuid: String) {
                // If we don't have a state for this screen yet, initialize it
                var state = self.sneakPeekStates[uuid] ?? SneakPeekState(targetScreenUUID: uuid)

                withAnimation(.smooth) {
                    state.show = status
                    state.type = type
                    state.value = value
                    state.icon = icon
                    state.accent = accent
                    state.targetScreenUUID = uuid // Ensure UUID is set
                    self.sneakPeekStates[uuid] = state
                }

                if status {
                    self.scheduleSneakPeekHide(for: uuid, duration: duration)
                } else {
                    self.sneakPeekTasks[uuid]?.cancel()
                    self.sneakPeekTasks[uuid] = nil
                }
            }

            if let targetUUID = targetScreenUUID {
                // Update specific screen
                updateState(for: targetUUID)
            } else {
                // Update ALL connected screens + the main screen as fallback
                // We use known screen UUIDs from NSScreen
                let screens = NSScreen.screens.compactMap { $0.displayUUID }
                if screens.isEmpty {
                    // Fallback if no screens detected (unlikely in UI app but safe)
                     if let mainUUID = NSScreen.main?.displayUUID {
                         updateState(for: mainUUID)
                     }
                } else {
                    for uuid in screens {
                        updateState(for: uuid)
                    }
                }
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    @MainActor
    func applyOSDSources() {
        guard Defaults[.osdReplacement],
              !NotchSpaceManager.shared.notchSpace.windows.isEmpty
        else {
            stopOSDIntegrations()
            return
        }

        // Built-in controls are the fallback if an external provider quits or
        // becomes unavailable while OSD replacement remains enabled.
        if !isBrightnessManagerObserving {
            BrightnessManager.shared.startObserving()
            isBrightnessManagerObserving = true
        }
        if !isVolumeManagerObserving {
            VolumeManager.shared.startObserving()
            isVolumeManagerObserving = true
        }

        let brightness = Defaults[.osdBrightnessSource]
        let volume = Defaults[.osdVolumeSource]
        let sourcesChanged =
            brightness != lastOSDBrightnessSource || volume != lastOSDVolumeSource
        lastOSDBrightnessSource = brightness
        lastOSDVolumeSource = volume

        let needsBetterDisplay = brightness == .betterDisplay || volume == .betterDisplay
        if needsBetterDisplay {
            if !isBetterDisplayObserving {
                BetterDisplayManager.shared.startObserving()
                isBetterDisplayObserving = true
            }
        } else if isBetterDisplayObserving {
            BetterDisplayManager.shared.stopObserving()
            isBetterDisplayObserving = false
        }

        if brightness == .lunar {
            if !isLunarOSDHidden {
                LunarManager.shared.configureLunarOSD(hide: true)
                isLunarOSDHidden = true
            }
            // The helper can stop its stream independently. Reconcile with
            // the manager's actual state rather than trusting a stale request flag.
            if !LunarManager.shared.isListening {
                LunarManager.shared.startListening()
            }
            isLunarListening = true
        } else {
            if isLunarListening {
                LunarManager.shared.stopListening()
                isLunarListening = false
            }
            if isLunarOSDHidden {
                LunarManager.shared.configureLunarOSD(hide: false)
                isLunarOSDHidden = false
            }
        }

        // Do not redo the async accessibility check for unrelated setting changes.
        if !isMediaKeyInterceptorRequested || sourcesChanged {
            osdEnableTask?.cancel()
            osdLifecycleGeneration &+= 1
            let generation = osdLifecycleGeneration
            isMediaKeyInterceptorRequested = true
            osdEnableTask = Task { @MainActor [weak self] in
                let started = await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                guard let self, self.osdLifecycleGeneration == generation else { return }
                self.isMediaKeyInterceptorRequested = started
                self.osdEnableTask = nil
            }
        }
    }

    /// Idempotent teardown for disabling replacement, removing notch windows,
    /// or terminating the app. Never constructs a manager just to stop it.
    @MainActor
    func stopOSDIntegrations() {
        osdLifecycleGeneration &+= 1
        osdEnableTask?.cancel()
        osdEnableTask = nil
        stopMediaKeyInterception()

        if isBrightnessManagerObserving {
            BrightnessManager.shared.stopObserving()
            isBrightnessManagerObserving = false
        }
        if isVolumeManagerObserving {
            VolumeManager.shared.stopObserving()
            isVolumeManagerObserving = false
        }
        if isBetterDisplayObserving {
            BetterDisplayManager.shared.stopObserving()
            isBetterDisplayObserving = false
        }
        if isLunarListening {
            LunarManager.shared.stopListening()
            isLunarListening = false
        }
        if isLunarOSDHidden {
            LunarManager.shared.configureLunarOSD(hide: false)
            isLunarOSDHidden = false
        }

        lastOSDBrightnessSource = nil
        lastOSDVolumeSource = nil
    }

    @MainActor
    private func stopMediaKeyInterception() {
        guard isMediaKeyInterceptorRequested || osdEnableTask != nil else { return }
        isMediaKeyInterceptorRequested = false
        MediaKeyInterceptor.shared.stop()
    }

    func shouldShowSneakPeek(on screenUUID: String?) -> Bool {
        guard let uuid = screenUUID else { return false }
        return sneakPeekStates[uuid]?.show == true
    }

    var isAnySneakPeekShowing: Bool {
        return sneakPeekStates.values.contains { $0.show }
    }

    // Helper to get state safely for binding/reading
    func sneakPeekState(for screenUUID: String?) -> SneakPeekState {
        guard let uuid = screenUUID else { return SneakPeekState() }
        return sneakPeekStates[uuid] ?? SneakPeekState(targetScreenUUID: uuid)
    }

    // Helper to get binding for SwiftUI views
    func binding(for screenUUID: String?) -> Binding<SneakPeekState> {
        Binding(
            get: { [weak self] in
                guard let self = self, let uuid = screenUUID else { return SneakPeekState() }
                return self.sneakPeekStates[uuid] ?? SneakPeekState(targetScreenUUID: uuid)
            },
            set: { [weak self] newValue in
                guard let self = self, let uuid = screenUUID else { return }
                self.sneakPeekStates[uuid] = newValue
            }
        )
    }

    private func scheduleSneakPeekHide(for screenUUID: String, duration: TimeInterval) {
        sneakPeekTasks[screenUUID]?.cancel()

        sneakPeekTasks[screenUUID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation {
                    // We only want to hide it, not reset everything instantly which might cause glitches
                    if var state = self.sneakPeekStates[screenUUID] {
                         state.show = false
                         // Optional: reset type to something default if needed, but keeping last state is often fine until next show
                         // keeping original logic:
                         state.type = .music
                         self.sneakPeekStates[screenUUID] = state
                    }
                }
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }

    func showEmpty() {
        currentView = .home
    }
}
