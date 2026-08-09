import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if appState.restartRequired {
                RestartRequiredBanner()
                Divider()
            }

            ModelCatalogStatusView(
                status: appState.modelCatalogStatus,
                compact: true
            )

            if appState.hasPersistentUndo {
                Label(
                    L10n.tr("Persistent Undo：%lld 筆", appState.receiptJournalEntries.count),
                    systemImage: "arrow.uturn.backward.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if appState.profileItems.contains(where: { $0.requiresLoopbackBridge }) {
                BridgeStatusBadge(status: appState.bridgeStatus)
                Text(verbatim: L10n.tr("需要時由 Apply 自動啟動；不需另外手動啟動。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if appState.profileItems.isEmpty {
                Text(verbatim: L10n.tr("尚無 profiles"))
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

            Button {
                openSettings()
            } label: {
                Label(L10n.tr("Settings"), systemImage: "gearshape")
            }

            Button(L10n.tr("Open Main Window")) {
                openWindow(id: "main")
            }

            Button(L10n.tr("Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            await appState.loadProfiles()
        }
    }
}
