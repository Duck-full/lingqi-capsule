import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                TodayView()
            }
            .tabItem { Label("今日", systemImage: "capsule.portrait") }

            NavigationStack {
                CapsuleTimelineView()
            }
            .tabItem { Label("胶囊", systemImage: "archivebox") }

            NavigationStack {
                ActionsView()
            }
            .tabItem { Label("行动", systemImage: "checklist") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(CapsuleDesign.accent)
    }
}
