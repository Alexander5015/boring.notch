//  BrightnessManager.swift
//  boringNotch
//
//  Created by JeanLouis on 08/22/24.

import AppKit

final class BrightnessManager: ObservableObject {
	static let shared = BrightnessManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var animatedBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared

	/// Key repeats arriving while an XPC call is in flight accumulate here so
	/// no press is lost — each press used to trigger its own 3-RPC sequence
	/// (adjust + read + display lookup), and they would queue behind each other.
	private var pendingDelta: Float = 0
	private var flushTask: Task<Void, Never>?
	private var pendingAbsoluteValue: Float?
	private var absoluteFlushTask: Task<Void, Never>?
	private var lifecycleGeneration: UInt64 = 0
	private let absoluteWriteInterval: Duration = .milliseconds(66)

	/// The brightness target display only changes with the display set.
	private var cachedTargetUUID: String?
	private var screenParametersObserver: (any NSObjectProtocol)?

	private init() {}

	func startObserving() {
		lifecycleGeneration &+= 1
		if screenParametersObserver == nil {
			screenParametersObserver = NotificationCenter.default.addObserver(
				forName: NSApplication.didChangeScreenParametersNotification,
				object: nil,
				queue: .main
			) { [weak self] _ in
				self?.cachedTargetUUID = nil
			}
		}
		refresh()
	}

	func stopObserving() {
		lifecycleGeneration &+= 1
		if let screenParametersObserver {
			NotificationCenter.default.removeObserver(screenParametersObserver)
			self.screenParametersObserver = nil
		}
		cachedTargetUUID = nil
		pendingDelta = 0
		pendingAbsoluteValue = nil
		flushTask?.cancel()
		flushTask = nil
		absoluteFlushTask?.cancel()
		absoluteFlushTask = nil
	}

	/// Determine which screen UUID should be used for brightness OSDs
	/// when the built‑in source is selected.  This mirrors the logic in the
	/// XPC helper, which chooses the menu-bar display if it supports brightness and
	/// otherwise falls back to an internal panel.
	/// Cached; invalidated when the display configuration changes.
	func brightnessTargetUUID() async -> String? {
		if let cachedTargetUUID { return cachedTargetUUID }
		var resolved: String?
		if let displayID = await client.displayIDForBrightness() {
			resolved = NSScreen.screens.first(where: { $0.cgDisplayID == displayID })?.displayUUID
		}
		resolved = resolved ?? NSScreen.main?.displayUUID
		cachedTargetUUID = resolved
		return resolved
	}

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		let generation = lifecycleGeneration
		Task { @MainActor [weak self] in
			guard let self,
			      let current = await self.client.currentScreenBrightness(),
			      !Task.isCancelled,
			      self.lifecycleGeneration == generation
			else { return }
			self.publish(brightness: current, touchDate: false)
		}
	}

	@MainActor func setRelative(delta: Float) {
		pendingDelta += delta
		guard flushTask == nil else { return }
		let generation = lifecycleGeneration
		flushTask = Task { @MainActor in
			defer {
				if lifecycleGeneration == generation {
					flushTask = nil
				}
			}
			while pendingDelta != 0 {
				guard !Task.isCancelled, lifecycleGeneration == generation else { return }
				let delta = pendingDelta
				pendingDelta = 0
				// One RPC delivers both the adjustment and the resulting value.
				guard let current = await client.adjustScreenBrightness(by: delta) else {
					guard !Task.isCancelled, lifecycleGeneration == generation else { return }
					refresh()
					return
				}
				guard !Task.isCancelled, lifecycleGeneration == generation else { return }
				publish(brightness: current, touchDate: true)

				let uuid = await brightnessTargetUUID()
				guard !Task.isCancelled, lifecycleGeneration == generation else { return }
				NotchUIEventBus.events.send(.sneakPeek(type: .brightness, value: CGFloat(current), targetScreenUUID: uuid))
			}
		}
	}

	@MainActor
	func setAbsolute(value: Float) {
		pendingAbsoluteValue = max(0, min(1, value))
		guard absoluteFlushTask == nil else { return }

		let generation = lifecycleGeneration
		absoluteFlushTask = Task { @MainActor in
			defer {
				if lifecycleGeneration == generation {
					absoluteFlushTask = nil
				}
			}

			while let target = pendingAbsoluteValue {
				guard !Task.isCancelled, lifecycleGeneration == generation else { return }
				pendingAbsoluteValue = nil
				let ok = await client.setScreenBrightness(target)
				guard !Task.isCancelled, lifecycleGeneration == generation else { return }

				guard ok else {
					refresh()
					return
				}

				publish(brightness: target, touchDate: true)
				let targetUUID = await brightnessTargetUUID()
				guard !Task.isCancelled, lifecycleGeneration == generation else { return }
				NotchUIEventBus.events.send(
					.sneakPeek(type: .brightness, value: CGFloat(target), targetScreenUUID: targetUUID)
				)

				// Slider input can arrive at display-refresh frequency. Apply the
				// latest pending value at roughly 15 Hz instead of issuing one XPC
				// write for every drag callback.
				if pendingAbsoluteValue != nil {
					try? await Task.sleep(for: absoluteWriteInterval)
				}
			}
		}
	}

	private func publish(brightness: Float, touchDate: Bool) {
		DispatchQueue.main.async {
			if self.rawBrightness != brightness || touchDate {
				if touchDate { self.lastChangeAt = Date() }
				self.rawBrightness = brightness
				self.animatedBrightness = brightness
			}
		}
	}
}

// (DisplayServices helpers moved into XPC helper)

// MARK: - Keyboard Backlight Controller
final class KeyboardBacklightManager: ObservableObject {
	static let shared = KeyboardBacklightManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let client = XPCHelperClient.shared

	/// Deltas accumulate while a read or set call is in flight so key repeats
	/// are coalesced into the next adjustment.
	private var pendingDelta: Float = 0
	private var flushTask: Task<Void, Never>?

	private init() { refresh() }

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentKeyboardBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		pendingDelta += delta
		guard flushTask == nil else { return }
		flushTask = Task { @MainActor in
			defer { flushTask = nil }
			while pendingDelta != 0 {
				let delta = pendingDelta
				pendingDelta = 0
				// Include changes made outside the app in every adjustment.
				guard let current = await client.currentKeyboardBrightness() else {
					refresh()
					return
				}
				let target = max(0, min(1, current + delta))
				let ok = await client.setKeyboardBrightness(target)
				if ok {
					publish(brightness: target, touchDate: true)
				} else {
					refresh()
					return
				}
				NotchUIEventBus.events.send(.sneakPeek(type: .backlight, value: CGFloat(target)))
			}
		}
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setKeyboardBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
			} else {
				refresh()
			}
		}
	}

	@MainActor private func publish(brightness: Float, touchDate: Bool) {
		if rawBrightness != brightness || touchDate {
			if touchDate { lastChangeAt = Date() }
			rawBrightness = brightness
		}
	}
}
