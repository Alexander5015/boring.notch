//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import Defaults
import SwiftUI

class MusicVisualizerModel: NSView, AudioCaptureLevelsConsumer {
    private var barLayers: [CAGradientLayer] = []
    private var isPlaying = false
    private var useRealtime = false
    private var useStatic = false
    private var tintColor: NSColor = .systemBlue
    private var lastTintColor: NSColor?

    private weak var attachedManager: AudioCaptureManager?
    private var lastAppliedLevels: [Float]
    private static let levelChangeThreshold: Float = 0.005
    private static let minBarScale: CGFloat = 0.12
    private static let idleBarScale: CGFloat = 0.3
    private static let animationKey = "scaleAnimation"

    private let barWidth: CGFloat = 2
    private let barCount = AudioCaptureManager.barCount
    private let spacing: CGFloat = 1
    private let totalHeight: CGFloat = 14

    override init(frame frameRect: NSRect) {
        self.lastAppliedLevels = [Float](repeating: 0, count: AudioCaptureManager.barCount)
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        self.lastAppliedLevels = [Float](repeating: 0, count: AudioCaptureManager.barCount)
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    deinit {
        attachedManager?.clearLevelsConsumer(self)
    }

    private func setupBars() {
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        if frame.width < totalWidth {
            frame.size = CGSize(width: totalWidth, height: totalHeight)
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        for i in 0..<barCount {
            let barLayer = CAGradientLayer()
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            applyFrame(to: barLayer, at: i, height: barWidth)
            barLayer.cornerRadius = barWidth / 2
            barLayer.contentsScale = scale
            barLayer.shouldRasterize = false
            barLayer.startPoint = CGPoint(x: 0.5, y: 0)
            barLayer.endPoint = CGPoint(x: 0.5, y: 1)
            barLayer.colors = [tintColor.withAlphaComponent(0.6).cgColor, tintColor.cgColor]
            layer?.addSublayer(barLayer)
            barLayers.append(barLayer)
        }
    }

    private func expandBars(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (index, barLayer) in barLayers.enumerated() {
            applyFrame(to: barLayer, at: index, height: totalHeight)
            barLayer.transform = CATransform3DMakeScale(1.0, Self.idleBarScale, 1.0)
        }
        CATransaction.commit()
    }

    private func collapseBarsToDots() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (index, barLayer) in barLayers.enumerated() {
            barLayer.removeAnimation(forKey: Self.animationKey)
            barLayer.transform = CATransform3DIdentity
            applyFrame(to: barLayer, at: index, height: barWidth)
        }
        CATransaction.commit()
    }

    private func startRandomAnimating() {
        for (index, barLayer) in barLayers.enumerated() {
            animateBar(barLayer, delay: Double(index) * 0.08)
        }
    }

    private func animateBar(_ barLayer: CAGradientLayer, delay: Double = 0) {
        guard isPlaying else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        var values: [CGFloat] = []
        var keyTimes: [NSNumber] = []
        let numSteps = 50
        let startValue = CGFloat.random(in: 0.3...1.0)
        for i in 0...numSteps {
            if i == 0 || i == numSteps {
                values.append(startValue)
            } else {
                values.append(CGFloat.random(in: 0.3...1.0))
            }
            keyTimes.append(NSNumber(value: Double(i) / Double(numSteps)))
        }
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = 15
        animation.repeatCount = .infinity
        animation.calculationMode = .cubic
        animation.beginTime = CACurrentMediaTime() + delay
        if #available(macOS 12.0, *) {
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 15)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.transform = CATransform3DMakeScale(1.0, startValue, 1.0)
        CATransaction.commit()
        barLayer.add(animation, forKey: Self.animationKey)
    }

    private func stopRandomAnimating() {
        for barLayer in barLayers {
            barLayer.removeAnimation(forKey: Self.animationKey)
        }
    }

    func setStaticMode(_ enabled: Bool) {
        guard useStatic != enabled else { return }
        useStatic = enabled
        for i in lastAppliedLevels.indices { lastAppliedLevels[i] = -1 }

        if enabled {
            stopRandomAnimating()
            applyStaticLevels()
        } else if isPlaying {
            if useRealtime {
                // Force the next capture update through the change threshold guard.
                syncCurrentLevelsFromAttachedManager()
            } else {
                startRandomAnimating()
            }
        }
    }

    private func applyStaticLevels() {
        // Interpolate a compact, fixed frequency profile across however many
        // bars the active audio-capture configuration provides.
        let profile: [CGFloat] = [0.20, 0.35, 0.58, 0.88, 0.72, 0.46, 0.80, 0.56, 0.30]
        let denominator = CGFloat(max(barLayers.count - 1, 1))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, barLayer) in barLayers.enumerated() {
            let position = CGFloat(index) / denominator * CGFloat(profile.count - 1)
            let lowerIndex = Int(position)
            let upperIndex = min(lowerIndex + 1, profile.count - 1)
            let fraction = position - CGFloat(lowerIndex)
            let scale = profile[lowerIndex] * (1 - fraction) + profile[upperIndex] * fraction
            barLayer.transform = CATransform3DMakeScale(1.0, scale, 1.0)
        }
        CATransaction.commit()
    }

    private func syncCurrentLevelsFromAttachedManager() {
        guard let manager = attachedManager else { return }
        syncCurrentLevels(from: manager)
    }

    func setPlaying(_ playing: Bool) {
        if useStatic {
            isPlaying = playing
            applyStaticLevels()
            return
        }

        guard isPlaying != playing else { return }
        isPlaying = playing
        if playing {
            expandBars(animated: true)
            if !useRealtime {
                startRandomAnimating()
            }
        } else {
            collapseBarsToDots()
        }
    }

    func setUseRealtime(_ enabled: Bool) {
        guard useRealtime != enabled else { return }
        useRealtime = enabled
        // Force the next incoming frame through the threshold guard.
        for i in 0..<lastAppliedLevels.count { lastAppliedLevels[i] = -1 }
        guard isPlaying else { return }
        if enabled {
            stopRandomAnimating()
        } else if useStatic {
            applyStaticLevels()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for barLayer in barLayers {
                barLayer.transform = CATransform3DMakeScale(1.0, Self.idleBarScale, 1.0)
            }
            CATransaction.commit()
            startRandomAnimating()
        }
    }

    func attach(to manager: AudioCaptureManager) {
        guard attachedManager !== manager else { return }
        attachedManager?.clearLevelsConsumer(self)
        attachedManager = manager
        manager.setLevelsConsumer(self)
    }

    func syncCurrentLevels(from manager: AudioCaptureManager) {
        guard attachedManager === manager,
              let values = manager.latestLevelsSnapshot() else { return }
        applyLevels(values)
    }

    func audioCaptureManager(_ manager: AudioCaptureManager, didProduceLevels values: [Float]) {
        applyLevels(values)
    }

    private func applyLevels(_ values: [Float]) {
        guard isPlaying, useRealtime, !useStatic, values.count == barCount else { return }
        var maxDelta: Float = 0
        for i in 0..<barCount {
            let d = abs(values[i] - lastAppliedLevels[i])
            if d > maxDelta { maxDelta = d }
        }
        guard maxDelta >= Self.levelChangeThreshold else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<barCount {
            let v = values[i]
            lastAppliedLevels[i] = v
            let clamped = max(Self.minBarScale, min(1.0, CGFloat(v)))
            barLayers[i].transform = CATransform3DMakeScale(1.0, clamped, 1.0)
        }
        CATransaction.commit()
    }

    func setTintColor(_ color: NSColor) {
        if let last = lastTintColor, last.isEqual(color) { return }
        lastTintColor = color
        tintColor = color
        let colors = [color.withAlphaComponent(0.6).cgColor, color.cgColor]
        barLayers.forEach { $0.colors = colors }
    }

    private func applyFrame(to barLayer: CALayer, at index: Int, height: CGFloat) {
        let x = CGFloat(index) * (barWidth + spacing)
        barLayer.bounds = CGRect(x: 0, y: 0, width: barWidth, height: height)
        barLayer.position = CGPoint(x: x + barWidth / 2, y: totalHeight / 2)
    }
}

struct MusicVisualizer: NSViewRepresentable {
    let isPlaying: Bool
    let tintColor: Color
    @Default(.realtimeAudioWaveform) var realtimeEnabled: Bool
    @Default(.staticSpectrogram) var staticSpectrogram: Bool
    @ObservedObject private var audioCapture = AudioCaptureManager.shared

    func makeNSView(context: Context) -> MusicVisualizerModel {
        let spectrum = MusicVisualizerModel()
        spectrum.setTintColor(NSColor(tintColor))
        spectrum.setStaticMode(staticSpectrogram)
        spectrum.setUseRealtime(realtimeEnabled && audioCapture.isCapturing)
        spectrum.setPlaying(isPlaying)
        spectrum.attach(to: audioCapture)
        spectrum.syncCurrentLevels(from: audioCapture)
        return spectrum
    }

    func updateNSView(_ nsView: MusicVisualizerModel, context: Context) {
        nsView.setTintColor(NSColor(tintColor))
        nsView.setStaticMode(staticSpectrogram)
        nsView.setUseRealtime(realtimeEnabled && audioCapture.isCapturing)
        nsView.setPlaying(isPlaying)
        nsView.syncCurrentLevels(from: audioCapture)
    }
}

#Preview {
    ZStack {
        Color.black
        MusicVisualizer(isPlaying: true, tintColor: .green)
            .frame(width: 18, height: 14)
    }
    .padding()
}
