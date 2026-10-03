//
//  OpenNotchContentView.swift
//  boringNotch
//
//  Scope 1: isolate the open panel's render tree from the closed notch.
//

import Defaults
import SwiftUI

@MainActor
struct OpenNotchContentView: View {
    @EnvironmentObject private var vm: BoringViewModel

    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var notificationManager = SystemNotificationManager.shared

    let albumArtNamespace: Namespace.ID
    let horizontalMediaGestureFeedback: CGFloat
    @Binding var isHoveringMusicArea: Bool

    var body: some View {
        VStack(spacing: 0) {
            if notificationManager.activeNotification == nil && !Defaults[.compactMode] {
                BoringHeader()
                    .frame(height: max(38, vm.effectiveClosedNotchHeight))
            }

            if let notification = notificationManager.activeNotification {
                NotificationExpandedView(notification: notification)
                    .id(notification.id)
            } else if Defaults[.compactMode] {
                CompactHomeView(
                    albumArtNamespace: albumArtNamespace,
                    horizontalMediaGestureFeedback: horizontalMediaGestureFeedback
                )
                .frame(width: 336)
                .onHover { hovering in
                    isHoveringMusicArea = hovering
                }
                .onDisappear {
                    isHoveringMusicArea = false
                }
            } else {
                switch coordinator.currentView {
                case .home:
                    NotchHomeView(
                        albumArtNamespace: albumArtNamespace,
                        horizontalMediaGestureFeedback: horizontalMediaGestureFeedback,
                        isHoveringMusicArea: $isHoveringMusicArea
                    )
                case .shelf:
                    ShelfView(
                        dropInteraction: vm.dropInteraction,
                        animation: vm.animation
                    )
                }
            }
        }
    }
}
