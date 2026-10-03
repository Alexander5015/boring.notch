//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import NotchTabHost
import SwiftUI

struct TabModel: Identifiable {
    let label: String
    let icon: String
    let view: NotchViews

    var id: String {
        switch view {
        case .home: "home"
        case .shelf: "shelf"
        case .extensionTab(let bundleID): bundleID
        }
    }
}

func builtInTabs() -> [TabModel] {
    [
        TabModel(label: "Home", icon: "house.fill", view: .home),
        TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)
    ]
}

@MainActor
func extensionTabs(_ registry: NotchTabRegistry) -> [TabModel] {
    registry.tabs.map {
        TabModel(label: $0.label, icon: $0.icon, view: .extensionTab(bundleID: $0.bundleID))
    }
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation

    var registry: NotchTabRegistry

    var body: some View {
        HStack(spacing: 0) {
            ForEach(builtInTabs() + extensionTabs(registry)) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}
