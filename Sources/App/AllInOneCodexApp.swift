import SwiftUI

@main
@MainActor
struct AllInOneCodexApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var appSettings = AppSettings()

    var body: some Scene {
        WindowGroup(L10n.tr("All-in-One Codex"), id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appSettings)
                .preferredColorScheme(appSettings.colorScheme)
        }

        MenuBarExtra(L10n.tr("Codex"), systemImage: "arrow.triangle.2.circlepath") {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appSettings)
                .preferredColorScheme(appSettings.colorScheme)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appSettings)
                .preferredColorScheme(appSettings.colorScheme)
        }
    }
}

private extension AppSettings {
    var colorScheme: ColorScheme? {
        switch appearance {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
