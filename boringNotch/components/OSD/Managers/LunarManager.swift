//
//  LunarManager.swift
//  boringNotch
//
//  Created by Alexander on 2026-02-07.
//

import AppKit
import CoreGraphics
import SwiftUI

@Observable
final class LunarManager {
    static let shared = LunarManager()

    private(set) var isLunarAvailable: Bool = false
    private(set) var isListening: Bool = false

    private var lastOSDHidden: Bool?
    private var eventListener: LunarEventListener?
    private var listeningGeneration = UUID()
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopTaskGeneration: UUID?
    private var configurationGeneration = UUID()
    private var configurationTask: Task<Void, Never>?
    private var availabilityGeneration = UUID()

    private init() {
        refreshAvailability()
    }

    // MARK: - Availability

    func refreshAvailability() {
        let generation = UUID()
        availabilityGeneration = generation
        Task.detached { [weak self] in
            let available = await XPCHelperClient.shared.isLunarAvailable()
            await MainActor.run {
                guard let self, self.availabilityGeneration == generation else { return }
                self.isLunarAvailable = available
            }
        }
    }

    // MARK: - Listening

    func startListening() {
        guard !isListening, startTask == nil else { return }

        let generation = UUID()
        listeningGeneration = generation
        let listener = eventListener ?? LunarEventListener(manager: self)
        eventListener = listener
        let pendingStop = stopTask

        startTask = Task { [weak self, listener, pendingStop] in
            // Serialize start behind any teardown already in progress. This
            // prevents a late stop from shutting down a newly opened stream.
            await pendingStop?.value
            guard !Task.isCancelled else {
                await MainActor.run {
                    if let self, self.listeningGeneration == generation {
                        self.startTask = nil
                    }
                }
                return
            }

            let isCurrent = await MainActor.run { () -> Bool in
                guard let self else { return false }
                return self.listeningGeneration == generation
            }
            guard isCurrent else { return }

            let started = await XPCHelperClient.shared.startLunarEventStream(listener: listener)
            guard let self else { return }

            let shouldKeepStream = await MainActor.run { () -> Bool in
                guard self.listeningGeneration == generation else { return false }
                self.startTask = nil
                self.isListening = started
                self.isLunarAvailable = started
                return true
            }

            // A stop request can arrive while XPC is starting the stream.
            // The serialized stop task will complete before any new start.
            if !shouldKeepStream && started {
                await XPCHelperClient.shared.stopLunarEventStream()
            }
        }
    }

    func stopListening() {
        guard isListening || startTask != nil else { return }

        listeningGeneration = UUID()
        let generation = listeningGeneration
        let pendingStart = startTask
        let previousStop = stopTask
        startTask?.cancel()
        startTask = nil
        isListening = false

        let stopID = UUID()
        stopTaskGeneration = stopID
        stopTask = Task { [weak self, pendingStart, previousStop] in
            await previousStop?.value
            await pendingStart?.value
            await XPCHelperClient.shared.stopLunarEventStream()

            await MainActor.run {
                guard let self, self.stopTaskGeneration == stopID else { return }
                self.stopTask = nil
                self.stopTaskGeneration = nil
                if self.listeningGeneration == generation {
                    self.isListening = false
                }
            }
        }
    }

    func configureLunarOSD(hide: Bool) {
        guard hide != lastOSDHidden else { return }
        lastOSDHidden = hide
        configurationGeneration = UUID()
        let generation = configurationGeneration
        let previousTask = configurationTask

        configurationTask = Task { [weak self, previousTask] in
            // Ensure restore/hide requests reach the helper in order. Tasks
            // superseded before dispatch simply skip their outdated command.
            await previousTask?.value
            guard !Task.isCancelled else { return }

            let isCurrent = await MainActor.run { () -> Bool in
                guard let self else { return false }
                return self.configurationGeneration == generation
            }
            guard isCurrent else { return }

            let succeeded = await XPCHelperClient.shared.setLunarOSDHidden(hide)
            await MainActor.run {
                guard let self, self.configurationGeneration == generation else { return }
                self.configurationTask = nil
                if !succeeded {
                    self.lastOSDHidden = nil
                }
            }
        }
    }

    // MARK: - Brightness Handling

    private func handleBrightnessChange(display: Int, brightness: Double) {
        let targetScreenUUID = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDirectDisplayID(number.uint32Value) == CGDirectDisplayID(display)
        }?.displayUUID

        let isSubZero = brightness < 0
        let isXDR = brightness > 1.0

        let normalizedBrightness: Double = switch true {
            case isSubZero: max(0, 1 + brightness)
            case isXDR:     min(1, brightness - 1)
            default:        brightness
        }

        let iconString: String = switch true {
            case isSubZero: "moon.circle"
            case isXDR:     "sun.max.circle"
            default:        ""
        }

        let accentColor: Color? = switch true {
            case isSubZero: Color(red: 1, green: 0.443, blue: 0.509)
            case isXDR:     Color(red: 0.58, green: 0.647, blue: 0.78)
            default:        nil
        }

        Task { @MainActor in
            NotchUIEventBus.events.send(.sneakPeek(
                type: .brightness,
                value: CGFloat(normalizedBrightness),
                icon: iconString,
                accent: accentColor,
                targetScreenUUID: targetScreenUUID
            ))
        }
    }

    fileprivate func handleLunarEvent(_ event: BNLunarBrightnessEvent) {
        handleBrightnessChange(display: event.display, brightness: event.brightness)
    }

    fileprivate func handleLunarStreamStopped(reason: String?) {
        Task { @MainActor in
            self.listeningGeneration = UUID()
            self.startTask?.cancel()
            self.startTask = nil
            self.isListening = false
            if reason != nil {
                self.isLunarAvailable = false
            }
        }
    }
}

@objc final class LunarEventListener: NSObject, BoringNotchXPCHelperLunarListener {
    weak var manager: LunarManager?

    init(manager: LunarManager) {
        self.manager = manager
        super.init()
    }

    func lunarEventDidUpdate(_ event: BNLunarBrightnessEvent) {
        manager?.handleLunarEvent(event)
    }

    func lunarStreamDidStop(_ reason: String?) {
        manager?.handleLunarStreamStopped(reason: reason)
    }
}
