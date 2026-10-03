//
//  ClosedNotchContentView.swift
//  boringNotch
//
//  Scope 1: keep the closed notch render tree isolated from the open panel.
//
//  The view owns only closed-state presentation. The parent keeps geometry,
//  input handling, and the open/close transition around it.
//

import AppKit
import Defaults
import SwiftUI

@MainActor
struct ClosedNotchContentView: View {
    @EnvironmentObject private var vm: BoringViewModel

    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject private var notificationManager = SystemNotificationManager.shared

    @Binding var activityIndex: Int
    @Binding var isHovering: Bool
    @Binding var gestureProgress: CGFloat

    let albumArtNamespace: Namespace.ID

    private let nowPlayingFallbackNoticeWidth: CGFloat = 330
    private let inlineMusicPeekLabelWidth: CGFloat = 110
    private let liveActivityEdgeMargin: CGFloat = 4

    private var isNotchHeightZero: Bool {
        vm.effectiveClosedNotchHeight == 0
    }

    private var displayClosedNotchHeight: CGFloat {
        isNotchHeightZero ? 10 : vm.effectiveClosedNotchHeight
    }

    private var cornerRadiusScaleFactor: CGFloat? {
        guard Defaults[.cornerRadiusScaling] else { return nil }
        let effectiveHeight = displayClosedNotchHeight
        guard effectiveHeight > 0 else { return nil }
        return effectiveHeight / 38.0
    }

    private var liveActivities: [LiveActivityItem] {
        var items: [LiveActivityItem] = []

        if let notification = notificationManager.activeNotification {
            items.append(.notification(notification))
        }

        let musicIsShowing = (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled

        if musicIsShowing || showingInlineMusicPeek {
            items.append(.music)
        }

        return items
    }

    private var shouldDisplayNowPlayingFallbackNotice: Bool {
        vm.notchState == .closed && nowPlayingFallbackNoticeActive
    }

    private var nowPlayingFallbackNoticeActive: Bool {
        guard musicManager.nowPlayingNotice != nil else { return false }

        let selectedScreen = NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
        let targetScreenUUID = selectedScreen?.displayUUID ?? NSScreen.main?.displayUUID
        let currentScreen = vm.screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let isConnected = vm.screenUUID == nil || currentScreen != nil
        let isTargetDisplay = vm.screenUUID == nil || vm.screenUUID == targetScreenUUID

        return isConnected
            && isTargetDisplay
            && !isNotchHeightZero
    }

    private var selectedActivity: LiveActivityItem? {
        guard !liveActivities.isEmpty else { return nil }
        return liveActivities[min(max(activityIndex, 0), liveActivities.count - 1)]
    }

    var body: some View {
        if vm.notchState == .closed {
            VStack(alignment: .leading) {
                VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    })
                    .frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if shouldDisplayNowPlayingFallbackNotice,
                       let notice = musicManager.nowPlayingNotice {
                        nowPlayingFallbackNotice(notice)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    } else if coordinator.expandingView.type == .battery
                                && coordinator.expandingView.show
                                && vm.notchState == .closed
                                && Defaults[.showPowerStatusNotifications] {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    maxAdapterWatts: batteryModel.maxAdapterWatts,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: displayClosedNotchHeight, alignment: .center)
                    } else if coordinator.shouldShowSneakPeek(on: vm.screenUUID)
                                && Defaults[.inlineOSD]
                                && coordinator.sneakPeekState(for: vm.screenUUID).type != .music
                                && coordinator.sneakPeekState(for: vm.screenUUID).type != .battery
                                && vm.notchState == .closed {
                        InlineOSD(
                            type: coordinator.binding(for: vm.screenUUID).type,
                            value: coordinator.binding(for: vm.screenUUID).value,
                            icon: coordinator.binding(for: vm.screenUUID).icon,
                            accent: coordinator.binding(for: vm.screenUUID).accent,
                            hoverAnimation: $isHovering,
                            gestureProgress: $gestureProgress
                        )
                        .transition(.opacity)
                    } else if !liveActivities.isEmpty && vm.notchState == .closed && !vm.hideOnClosed {
                        LiveActivityStack(items: liveActivities, index: $activityIndex) { item in
                            switch item {
                            case .notification(let notification):
                                NotificationLiveActivity(notification: notification)
                            case .music:
                                MusicLiveActivity()
                                    .frame(alignment: .center)
                            }
                        }
                    } else if !coordinator.expandingView.show
                                && vm.notchState == .closed
                                && !musicManager.isPlaying
                                && musicManager.isPlayerIdle
                                && Defaults[.showNotHumanFace]
                                && !vm.hideOnClosed {
                        boringFaceAnimation
                    } else if !vm.hasNotch {
                        Rectangle()
                            .fill(.clear)
                            .frame(
                                width: vm.closedNotchSize.width - 20,
                                height: 11
                            )
                    } else {
                        Rectangle()
                            .fill(.clear)
                            .frame(
                                width: vm.closedNotchSize.width - 20,
                                height: displayClosedNotchHeight
                            )
                    }

                    if coordinator.shouldShowSneakPeek(on: vm.screenUUID) {
                        if coordinator.sneakPeekState(for: vm.screenUUID).type != .music
                            && coordinator.sneakPeekState(for: vm.screenUUID).type != .battery
                            && !Defaults[.inlineOSD]
                            && vm.notchState == .closed {
                            SystemEventIndicatorModifier(
                                eventType: coordinator.binding(for: vm.screenUUID).type,
                                value: coordinator.binding(for: vm.screenUUID).value,
                                icon: coordinator.binding(for: vm.screenUUID).icon,
                                accent: coordinator.binding(for: vm.screenUUID).accent,
                                sendEventBack: { newVal in
                                    switch coordinator.sneakPeekState(for: vm.screenUUID).type {
                                    case .volume:
                                        VolumeManager.shared.setAbsolute(Float32(newVal))
                                    case .brightness:
                                        BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                    default:
                                        break
                                    }
                                }
                            )
                            .padding(.bottom, 10)
                            .padding(.leading, 4)
                            .padding(.trailing, 8)
                        } else if coordinator.sneakPeekState(for: vm.screenUUID).type == .music
                                    && vm.notchState == .closed
                                    && !vm.hideOnClosed
                                    && Defaults[.sneakPeekStyles] == .standard {
                            HStack(alignment: .center) {
                                Image(systemName: "music.note")
                                GeometryReader { geo in
                                    MarqueeText(
                                        musicManager.songTitle + " - " + musicManager.artistName,
                                        color: Defaults[.playerColorTinting]
                                            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
                                            : .gray,
                                        delayDuration: 1.0,
                                        frameWidth: geo.size.width
                                    )
                                }
                            }
                            .foregroundStyle(.gray)
                            .padding(.bottom, 10)
                        }
                    }
                }
            }
            .conditionalModifier(
                (
                    coordinator.shouldShowSneakPeek(on: vm.screenUUID)
                        && coordinator.sneakPeekState(for: vm.screenUUID).type == .music
                        && vm.notchState == .closed
                        && !vm.hideOnClosed
                        && Defaults[.sneakPeekStyles] == .standard
                )
                || (
                    coordinator.shouldShowSneakPeek(on: vm.screenUUID)
                        && coordinator.sneakPeekState(for: vm.screenUUID).type != .music
                        && vm.notchState == .closed
                )
            ) { view in
                view.fixedSize()
            }
            .zIndex(1)
        }
        } else {
            EmptyView()
        }
    }

    private var boringFaceAnimation: some View {
        HStack {
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + 20)

            let faceScale = min(1.0, displayClosedNotchHeight / 30.0)
            AnimatedFace(
                height: 24.0 * faceScale,
                width: 30.0 * faceScale
            )
        }
        .frame(
            height: displayClosedNotchHeight,
            alignment: .center
        )
    }

    private var showingInlineMusicPeek: Bool {
        coordinator.expandingView.show
            && coordinator.expandingView.type == .music
            && Defaults[.sneakPeekStyles] == .inline
    }

    private var musicActivityCenterWidth: CGFloat {
        let margin = vm.closedNotchSize.width - 4 + (2 * liveActivityEdgeMargin)
        guard showingInlineMusicPeek else { return margin }
        return margin + (2 * inlineMusicPeekLabelWidth)
    }

    private var musicLiveActivity: some View {
        HStack(spacing: 0) {
            let baseArtSize = displayClosedNotchHeight - 12
            let scaledArtSize: CGFloat = {
                if let scale = cornerRadiusScaleFactor {
                    return displayClosedNotchHeight - 12 * scale
                }
                return baseArtSize
            }()
            let artVerticalInset = (displayClosedNotchHeight - scaledArtSize) / 2

            let closedCornerRadius: CGFloat = {
                let base = MusicPlayerImageSizes.cornerRadiusInset.closed
                if let scale = cornerRadiusScaleFactor {
                    return max(0, base * scale)
                }
                return base
            }()

            Image(nsImage: musicManager.albumArt)
                .resizable()
                .scaledToFit()
                .clipShape(
                    RoundedRectangle(cornerRadius: closedCornerRadius)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(width: scaledArtSize, height: scaledArtSize)
                .offset(x: artVerticalInset - liveActivityEdgeMargin)

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .center) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music {
                            MarqueeText(
                                musicManager.songTitle,
                                color: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor)
                                    : Color.gray,
                                delayDuration: 0.4,
                                frameWidth: inlineMusicPeekLabelWidth
                            )
                            .opacity(
                                coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline
                                    ? 1
                                    : 0
                            )

                            Spacer(minLength: vm.closedNotchSize.width)

                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: inlineMusicPeekLabelWidth, alignment: .trailing)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline
                                        ? 1
                                        : 0
                                )
                        }
                    }
                    .padding(.horizontal, 8)
                )
                .frame(width: musicActivityCenterWidth)

            HStack {
                MusicVisualizer(
                    isPlaying: musicManager.isPlaying,
                    tintColor: Defaults[.coloredSpectrogram]
                        ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.5)
                        : Color.gray
                )
                .frame(width: 18, height: 12)
            }
            .frame(
                width: max(
                    0,
                    displayClosedNotchHeight - 12 + gestureProgress / 2
                ),
                height: max(0, displayClosedNotchHeight - 12),
                alignment: .center
            )
        }
        .frame(height: displayClosedNotchHeight, alignment: .center)
    }

    private func nowPlayingFallbackNotice(_ notice: NowPlayingFallbackNotice) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(notice.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .lineLimit(2)

            Spacer(minLength: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: nowPlayingFallbackNoticeWidth)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
        .onAppear {
            if musicManager.markNowPlayingNoticePresented(notice.id) {
                announceNowPlayingFallbackNotice(notice)
            }
        }
    }

    private func announceNowPlayingFallbackNotice(_ notice: NowPlayingFallbackNotice) {
        let announcement = "\(String(localized: notice.title)). \(String(localized: notice.subtitle))."
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

private extension ClosedNotchContentView {
    func MusicLiveActivity() -> some View {
        musicLiveActivity
    }
}
