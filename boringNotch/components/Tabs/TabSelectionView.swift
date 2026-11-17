//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let allTabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Notes", icon: "note.text", view: .notes),
    TabModel(label: "System", icon: "thermometer.medium", view: .system),
    TabModel(label: "Awake", icon: "cup.and.saucer.fill", view: .awake)
]

/// Left of the hardware notch there's only room for ~3 tabs (~172pt with a 224pt notch);
/// the rest sit right of it, before the settings icon.
let leadingTabCount = 3

/// The saved order (Settings > Appearance > Tabs), with tabs it doesn't mention (e.g. new ones) appended.
func completeTabOrder(_ order: [NotchViews]) -> [NotchViews] {
    let known = order.filter { view in allTabs.contains { $0.view == view } }
    return known + allTabs.map(\.view).filter { !known.contains($0) }
}

struct TabSelectionView: View {
    /// false: tabs left of the notch, true: tabs right of it.
    var trailing = false
    @Default(.tabOrder) private var tabOrder
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation

    private var tabs: [TabModel] {
        let visible = completeTabOrder(tabOrder)
            .filter { $0 != .shelf || Defaults[.boringShelf] }
            .compactMap { view in allTabs.first { $0.view == view } }
        return trailing ? Array(visible.dropFirst(leadingTabCount)) : Array(visible.prefix(leadingTabCount))
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
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
    BoringHeader().environmentObject(BoringViewModel())
}
