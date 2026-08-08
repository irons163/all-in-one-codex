import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appState.profileItems.isEmpty {
                Text("尚無 profiles")
            } else {
                ForEach(appState.profileItems) { item in
                    Button {
                        Task { await appState.quickApply(profileID: item.id) }
                    } label: {
                        HStack {
                            Image(systemName: item.isActive ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text(item.providerName)
                                    .foregroundStyle(.secondary)
                                if item.requiresLoopbackBridge,
                                   let bridgeStatus = item.bridgeStatus
                                {
                                    BridgeStatusBadge(status: bridgeStatus)
                                    .font(.caption2)
                                }
                            }
                        }
                    }
                    .disabled(appState.isBusy)
                }
            }

            Divider()

            Button("Open Main Window") {
                openWindow(id: "main")
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            await appState.loadProfiles()
        }
    }
}
