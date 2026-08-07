import SwiftUI

@main
@MainActor
struct AllInOneCodexApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("All-in-One Codex", id: "main") {
            ContentView()
                .environmentObject(appState)
        }

        MenuBarExtra("Codex", systemImage: "arrow.triangle.2.circlepath") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)
    }
}
