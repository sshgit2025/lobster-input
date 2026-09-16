import SwiftUI
import UIKit

struct MainTabView: View {

    @State private var selectedTab = 0
    @EnvironmentObject private var languageStore: MobileLanguageStore

    init() {
        // 导航栏：透明显示水蓝底，标题用品牌深蓝
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.backgroundColor = LobsterWaterPalette.panel
        navAppearance.shadowColor = .clear
        navAppearance.titleTextAttributes = [.foregroundColor: LobsterWaterPalette.text]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: LobsterWaterPalette.text]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        // 标签栏：不透明白底，扁平干净
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = .white
        tabAppearance.shadowColor = LobsterWaterPalette.border
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label(L10n.tabHome, systemImage: "mic.fill")
                }
                .tag(0)

            HistoryView()
                .tabItem {
                    Label(L10n.tabHistory, systemImage: "clock.arrow.circlepath")
                }
                .tag(1)

            PersonaView()
                .tabItem {
                    Label(L10n.tabPersona, systemImage: "person.text.rectangle")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label(L10n.tabSettings, systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .id(languageStore.language.rawValue)
        .tint(LobsterWaterPalette.accentColor)
        .onOpenURL { url in
            guard url.scheme == "lobster-input" else { return }
            if url.host == "record" {
                selectedTab = 0
            }
        }
    }
}
