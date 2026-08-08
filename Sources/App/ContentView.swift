import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            profileSidebar
        } detail: {
            detailContent
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.beginCreatingProfile()
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button {
                    Task { await appState.undoLastSwitch() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(appState.isBusy)
            }
        }
        .sheet(
            isPresented: $appState.isShowingNewProfile,
            onDismiss: appState.cancelCreatingProfile
        ) {
            NavigationStack {
                ProfileEditorView(
                    draft: $appState.editorDraft,
                    isNew: true
                )
                .environmentObject(appState)
            }
            .frame(minWidth: 520, minHeight: 520)
        }
        .alert(
            "操作失敗",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.errorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "發生未知錯誤。")
        }
        .onChange(of: appState.selectedProfileID) { _, _ in
            appState.prepareEditorForSelection()
        }
        .task {
            await appState.loadProfiles()
        }
    }

    private var profileSidebar: some View {
        List(selection: $appState.selectedProfileID) {
            if appState.profileItems.isEmpty {
                ContentUnavailableView(
                    "尚無 Profiles",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("使用上方 + 建立第一個 provider profile。")
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(appState.profileItems) { item in
                    ProfileRow(item: item)
                        .tag(item.id)
                }
            }
        }
        .navigationTitle("Profiles")
        .safeAreaInset(edge: .bottom) {
            if appState.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("處理中…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if appState.selectedProfileItem != nil {
            ProfileEditorView(
                draft: $appState.editorDraft,
                isNew: false
            )
            .environmentObject(appState)
        } else {
            EmptyStateView {
                appState.beginCreatingProfile()
            }
        }
    }
}

private struct ProfileRow: View {
    let item: AppState.ProfileListItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isActive ? .green : .secondary)
                .accessibilityLabel(item.isActive ? "已套用" : "未套用")

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.providerName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if item.requiresLoopbackBridge,
                   let bridgeStatus = item.bridgeStatus
                {
                    BridgeStatusBadge(status: bridgeStatus)
                        .font(.caption2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.name), \(item.providerName), \(item.model), \(item.isActive ? "已套用" : "未套用")"
        )
    }
}

struct BridgeStatusBadge: View {
    let status: OpenCodeGoBridgeStatus

    var body: some View {
        Label(status.displayName, systemImage: status.systemImage)
            .foregroundStyle(status.tint)
    }
}

private extension OpenCodeGoBridgeStatus {
    var displayName: String {
        switch self {
        case .running:
            return "Bridge：執行中"
        case .stopped:
            return "Bridge：未啟動"
        }
    }

    var systemImage: String {
        switch self {
        case .running:
            return "checkmark.circle.fill"
        case .stopped:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running:
            return .green
        case .stopped:
            return .orange
        }
    }
}

private struct EmptyStateView: View {
    let createProfile: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("選擇或建立 Profile", systemImage: "rectangle.split.3x1")
        } description: {
            Text("建立 profile 後，可預覽並安全套用 Codex provider 設定。")
        } actions: {
            Button("建立 Profile", action: createProfile)
                .buttonStyle(.borderedProminent)
        }
    }
}
