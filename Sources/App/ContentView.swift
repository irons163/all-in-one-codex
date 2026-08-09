import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if appState.restartRequired {
                RestartRequiredBanner()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            NavigationSplitView {
                profileSidebar
            } detail: {
                detailContent
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.beginCreatingProfile()
                } label: {
                    Label(L10n.tr("New Profile"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button {
                    Task { await appState.undoLastSwitch() }
                } label: {
                    Label(L10n.tr("Undo"), systemImage: "arrow.uturn.backward")
                }
                .disabled(appState.isBusy || !appState.canUndoLastSwitch)

                Button {
                    appState.beginRestore()
                } label: {
                    Label(L10n.tr("Restore Backup"), systemImage: "arrow.counterclockwise")
                }
                .disabled(appState.isBusy)

                Button {
                    openSettings()
                } label: {
                    Label(L10n.tr("Settings"), systemImage: "gearshape")
                }
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
        .sheet(
            isPresented: $appState.isShowingRestore,
            onDismiss: appState.cancelRestore
        ) {
            NavigationStack {
                RestoreBackupView()
                    .environmentObject(appState)
            }
            .frame(minWidth: 560, minHeight: 560)
        }
        .alert(
            L10n.tr("操作失敗"),
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.errorMessage = nil
                    }
                }
            )
        ) {
            Button(L10n.tr("好"), role: .cancel) {}
        } message: {
            Text(verbatim: appState.errorMessage ?? L10n.tr("發生未知錯誤。"))
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
                    L10n.tr("尚無 Profiles"),
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text(verbatim: L10n.tr("使用上方 + 建立第一個 provider profile。"))
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(appState.profileItems) { item in
                    ProfileRow(item: item)
                        .tag(item.id)
                }
            }
        }
        .navigationTitle(L10n.tr("Profiles"))
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if let selectedProfileItem = appState.selectedProfileItem,
                   selectedProfileItem.requiresLoopbackBridge
                {
                    BridgeStatusBadge(status: appState.bridgeStatus)
                    Text(verbatim: L10n.tr("需要 bridge 時，Apply 會自動啟動；不需另外手動啟動。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ModelCatalogStatusView(
                    status: appState.modelCatalogStatus,
                    compact: true
                )

                if appState.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: L10n.tr("處理中…"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
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

struct SettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        Form {
            Section(L10n.tr("Appearance")) {
                Picker(L10n.tr("Appearance"), selection: $appSettings.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section(L10n.tr("Language")) {
                Picker(L10n.tr("Language"), selection: $appSettings.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName)
                            .tag(language)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 430)
        .navigationTitle(L10n.tr("Settings"))
    }
}

private struct RestoreBackupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pendingBackup: CodexConfigurationBackup?

    var body: some View {
        VStack(spacing: 0) {
            if appState.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: L10n.tr("Restore 處理中…"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }

            List {
                Section(L10n.tr("Config backups")) {
                    if appState.restoreBackups.isEmpty {
                        ContentUnavailableView(
                            L10n.tr("尚無可用的 config backups"),
                            systemImage: "archivebox",
                            description: Text(verbatim: L10n.tr(
                                "完成一次 Apply 後，App 建立的 config.toml backup 會出現在這裡。"
                            ))
                        )
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(appState.restoreBackups) { backup in
                            Button {
                                pendingBackup = backup
                            } label: {
                                RestoreBackupRow(backup: backup)
                            }
                            .buttonStyle(.plain)
                            .disabled(appState.isBusy)
                        }
                    }
                }

                Section(L10n.tr("Undo journal")) {
                    if appState.receiptJournalEntries.isEmpty {
                        Text(verbatim: L10n.tr("尚無 persistent Undo journal。成功 Apply 或 Restore 後會自動保留。"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.receiptJournalEntries) { entry in
                            UndoJournalRow(entry: entry)
                        }
                    }
                }
            }
            .listStyle(.inset)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(verbatim: L10n.tr(
                    "Restore 只會復原 config.toml 與 app-owned model catalog；"
                    + "不會複製或刪除 sessions、history，也不會搬移約 20GB 的 session data。"
                    + "完成後請完全退出並重新啟動 Codex。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .navigationTitle(L10n.tr("Restore Backup"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("Cancel")) {
                    appState.cancelRestore()
                }
                .disabled(appState.isBusy)
            }
        }
        .alert(
            L10n.tr("確認 Restore Backup？"),
            isPresented: Binding(
                get: { pendingBackup != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingBackup = nil
                    }
                }
            )
        ) {
            Button(L10n.tr("Restore Backup"), role: .destructive) {
                guard let pendingBackup else { return }
                self.pendingBackup = nil
                Task {
                    await appState.restore(pendingBackup)
                }
            }
            .disabled(appState.isBusy)
            Button(L10n.tr("Cancel"), role: .cancel) {
                pendingBackup = nil
            }
            .disabled(appState.isBusy)
        } message: {
            if let pendingBackup {
                Text(verbatim: L10n.tr(
                    "時間：%@\n大小：%@\n\n"
                    + "這是第二步確認。只會復原 config.toml 與 app-owned model catalog，"
                    + "不會修改 auth、sessions、history 或 state database。完成後必須完全重啟 Codex。",
                    formattedDate(pendingBackup.date),
                    formattedByteSize(pendingBackup.byteSize)
                ))
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func formattedByteSize(_ byteSize: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

private struct RestoreBackupRow: View {
    let backup: CodexConfigurationBackup

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.arrow.up")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.body)
                Text(ByteCountFormatter.string(fromByteCount: backup.byteSize, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.tr(
                "%@, %@",
                backup.date.formatted(date: .abbreviated, time: .shortened),
                ByteCountFormatter.string(fromByteCount: backup.byteSize, countStyle: .file)
            )
        )
    }
}

private struct UndoJournalRow: View {
    let entry: SwitchReceiptJournalEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.profileName ?? L10n.tr("Config backup restore"))
                    .font(.body)
                if let providerDisplayName = entry.providerDisplayName,
                   let model = entry.model
                {
                    Text(verbatim: L10n.tr("%@ · %@", providerDisplayName, model))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: L10n.tr("config.toml + app-owned model catalog"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileRow: View {
    let item: AppState.ProfileListItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isActive ? .green : .secondary)
                .accessibilityLabel(item.isActive ? L10n.tr("已套用") : L10n.tr("未套用"))

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
            L10n.tr(
                "%@, %@, %@, %@",
                item.name,
                item.providerName,
                item.model,
                item.isActive ? L10n.tr("已套用") : L10n.tr("未套用")
            )
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

struct RestartRequiredBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: L10n.tr("需要重新啟動 Codex"))
                    .font(.headline)
                Text(AppState.restartRequiredMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(L10n.tr("隱藏")) {
                appState.dismissRestartRequired()
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.tr("需要重新啟動 Codex。%@", AppState.restartRequiredMessage)
        )
    }
}

struct ModelCatalogStatusView: View {
    let status: AppState.ModelCatalogStatus
    let compact: Bool

    init(status: AppState.ModelCatalogStatus, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            switch status.state {
            case .pending:
                Label(
                    L10n.tr("Codex model catalog：Apply 時建立"),
                    systemImage: "doc.badge.plus"
                )
                .foregroundStyle(.secondary)
            case .applied:
                if let modelCount = status.modelCount {
                    Label(
                        L10n.tr("已建立 Codex model catalog（%lld 個 models）", modelCount),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                } else {
                    Label(
                        L10n.tr("已建立 Codex model catalog"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                }
            case .restored:
                Label(
                    L10n.tr("Codex model catalog：已隨 Undo 復原"),
                    systemImage: "arrow.uturn.backward.circle"
                )
                .foregroundStyle(.secondary)
            }

            if compact {
                Text(verbatim: L10n.tr("Apply 後需完全退出並重新啟動 Codex，才能讀取 catalog。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: L10n.tr(
                    "OpenCode Go 的 All-in-One model picker 包含 DeepSeek 等 custom models；"
                    + "Apply 後需重啟 Codex 才會重新讀取 catalog。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .font(compact ? .caption : .callout)
    }
}

private extension OpenCodeGoBridgeStatus {
    var displayName: String {
        switch self {
        case .running:
            return L10n.tr("Bridge：執行中")
        case .stopped:
            return L10n.tr("Bridge：Apply 時自動啟動")
        }
    }

    var systemImage: String {
        switch self {
        case .running:
            return "checkmark.circle.fill"
        case .stopped:
            return "bolt.horizontal.circle"
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
            Label(L10n.tr("選擇或建立 Profile"), systemImage: "rectangle.split.3x1")
        } description: {
            Text(verbatim: L10n.tr("建立 profile 後，可預覽並安全套用 Codex provider 設定。"))
        } actions: {
            Button(L10n.tr("建立 Profile"), action: createProfile)
                .buttonStyle(.borderedProminent)
        }
    }
}
