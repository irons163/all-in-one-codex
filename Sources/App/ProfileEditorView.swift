import SwiftUI

struct ProfileEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var draft: AppState.ProfileDraft
    let isNew: Bool

    var body: some View {
        Form {
            Section(L10n.tr("Profile")) {
                TextField(L10n.tr("Name"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            Section(L10n.tr("Provider")) {
                Picker(L10n.tr("Provider"), selection: $draft.presetKey) {
                    ForEach(appState.presetOptions) { option in
                        Text(option.name)
                            .tag(option.id)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(L10n.tr("Model"), text: $draft.model)
                        .textFieldStyle(.roundedBorder)
                        .help(route.explanation)

                    Menu {
                        ForEach(appState.modelOptions(for: draft.presetKey)) { option in
                            Button {
                                draft.model = option.modelID
                            } label: {
                                HStack {
                                    Image(
                                        systemName: option.isChatOnly
                                            ? "arrow.left.arrow.right"
                                            : "arrow.right"
                                    )
                                    Text(option.modelID)
                                    Spacer()
                                    Text(option.transport.label)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if appState.allowsCustomModels(for: draft.presetKey) {
                            Divider()
                            Text(verbatim: L10n.tr("OpenRouter 允許直接輸入自訂 model ID"))
                        }
                    } label: {
                        Label(L10n.tr("選擇 model"), systemImage: "chevron.up.chevron.down")
                    }
                    .fixedSize()
                    .help(L10n.tr("從 preset 的 model catalog 選擇；仍可直接輸入文字。"))
                }

                LabeledContent(L10n.tr("Route")) {
                    Text(route.routeName)
                        .foregroundStyle(route.isKnown ? Color.primary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }

                if route.bridgeEnabled,
                   let bridgeStatus = route.bridgeStatus
                {
                    LabeledContent(L10n.tr("Bridge")) {
                        BridgeStatusBadge(status: bridgeStatus)
                    }
                }

                LabeledContent(L10n.tr("Endpoint")) {
                    Text(route.endpoint)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                if let loopbackEndpoint = route.loopbackEndpoint {
                    LabeledContent(L10n.tr("Loopback")) {
                        Text(loopbackEndpoint)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let upstreamEndpoint = route.upstreamEndpoint {
                    LabeledContent(L10n.tr("Upstream")) {
                        Text(upstreamEndpoint)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Text(route.explanation)
                    .font(.caption)
                    .foregroundStyle(
                        route.bridgeEnabled && route.bridgeStatus != .running
                            ? Color.orange
                            : Color.secondary
                    )

                if route.bridgeEnabled {
                    Label(
                        L10n.tr("Bridge 會在 Apply 時由 All-in-One Codex 自動啟動；不需另外手動啟動。"),
                        systemImage: "bolt.horizontal.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !route.isKnown {
                    Label(
                        L10n.tr("Core 會拒絕這個 model；請從清單選擇支援項目或修正輸入。"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section(L10n.tr("Session compatibility")) {
                Toggle(L10n.tr("保留既有 Codex sessions"), isOn: $draft.preserveSessions)

                Text(verbatim: L10n.tr(
                    "保留 Codex 內建 openai provider namespace，讓既有 task 在完全重啟 Codex 後仍可見並重新開啟。"
                    + "所有請求會經本機 proxy，API key 仍只由 Keychain 提供。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                if draft.preserveSessions {
                    Label(
                        L10n.tr("使用期間請保持 All-in-One Codex 開啟；正在執行中的 task 不會熱切換。"),
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section(L10n.tr("Codex model catalog")) {
                if let modelCatalogCount {
                    Label(
                        modelCatalogMatches
                            ? L10n.tr("已建立 Codex model catalog（%lld 個 models）", modelCatalogCount)
                            : L10n.tr("Apply 時建立 Codex model catalog（%lld 個 models）", modelCatalogCount),
                        systemImage: modelCatalogMatches
                            ? "checkmark.circle.fill"
                            : "doc.badge.plus"
                    )
                    .foregroundStyle(modelCatalogMatches ? Color.green : Color.secondary)
                } else {
                    Label(
                        L10n.tr("Apply 時建立 Codex model catalog；請選擇有效 model。"),
                        systemImage: "doc.badge.plus"
                    )
                    .foregroundStyle(.secondary)
                }

                Text(verbatim: L10n.tr(
                    "OpenCode Go 的 model picker 仍來自 All-in-One source list，包含 DeepSeek 等 custom models；"
                    + "這裡只顯示摘要，不會把完整 catalog JSON 放到主畫面。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(verbatim: L10n.tr("Apply 後 Codex App/CLI 不會熱載入 catalog；請完全退出並重新啟動。保留模式可再開啟既有 task。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.modelCatalogStatus.isApplied, !modelCatalogMatches {
                    Text(verbatim: L10n.tr("目前已套用的 catalog 對應另一個 profile 或 model；再次 Apply 會更新它。"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(L10n.tr("Credentials")) {
                SecureField(L10n.tr("New API key"), text: $draft.apiKey)
                    .textFieldStyle(.roundedBorder)

                Text(verbatim: L10n.tr("只接受新的 API key；儲存成功後欄位會清空。既有 key 不會讀出或顯示。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch appState.editorCredentialStatus {
                case .missing:
                    Label(
                        L10n.tr("尚未設定 API key；Apply 前請先輸入。"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                case .saved:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("********")
                            .font(.system(.caption, design: .monospaced))
                        Text(verbatim: L10n.tr("API key 已儲存；輸入新值可替換。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .newValue:
                    Label(
                        L10n.tr("新的 API key 將在 Save 或 Apply 時儲存。"),
                        systemImage: "key.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let preview = appState.preview,
               preview.profileID == draft.id || isNew
            {
                PreviewSection(preview: preview)
            }

            Section {
                HStack {
                    if isNew {
                        Button(L10n.tr("Cancel")) {
                            appState.cancelCreatingProfile()
                        }
                    }

                    Spacer()

                    Button {
                        Task { await appState.previewEditor() }
                    } label: {
                        Label(L10n.tr("Preview"), systemImage: "eye")
                    }
                    .disabled(appState.isBusy || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task { await appState.saveEditor() }
                    } label: {
                        Label(L10n.tr("Save Profile"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isBusy)

                    if !isNew {
                        Button {
                            Task { await appState.applySelectedProfile() }
                        } label: {
                            Label(L10n.tr("Apply"), systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            appState.isBusy
                                || appState.editorCredentialStatus == .missing
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? L10n.tr("New Profile") : (draft.name.isEmpty ? L10n.tr("Profile") : draft.name))
        .onChange(of: draft.presetKey) { oldKey, newKey in
            if draft.model.isEmpty || appState.isDefaultModel(draft.model, for: oldKey) {
                draft.model = appState.defaultModel(for: newKey)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let statusMessage = appState.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 7)
                    .background(.bar)
            }
        }
    }

    private var route: AppState.RoutePresentation {
        appState.routePresentation(
            for: draft.presetKey,
            model: draft.model,
            preserveSessions: draft.preserveSessions
        )
    }

    private var modelCatalogCount: Int? {
        appState.modelCatalogCount(
            for: draft.presetKey,
            model: draft.model
        )
    }

    private var modelCatalogMatches: Bool {
        appState.modelCatalogStatus.matches(
            profileID: draft.id,
            model: draft.model
        )
    }
}

private struct PreviewSection: View {
    let preview: AppState.PreviewSnapshot

    var body: some View {
        Section(L10n.tr("Preview")) {
            Text(preview.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent(L10n.tr("Profile")) {
                Text(preview.profileName)
            }
            LabeledContent(L10n.tr("Provider")) {
                Text(preview.providerName)
            }
            LabeledContent(L10n.tr("Route")) {
                Text(preview.routeName)
                    .foregroundStyle(
                        preview.bridgeEnabled && preview.bridgeStatus != .running
                            ? Color.orange
                            : Color.secondary
                    )
            }
            if preview.bridgeEnabled,
               let bridgeStatus = preview.bridgeStatus
            {
                LabeledContent(L10n.tr("Bridge")) {
                    BridgeStatusBadge(status: bridgeStatus)
                }
            }
            LabeledContent(L10n.tr("Endpoint")) {
                Text(preview.endpoint)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let loopbackEndpoint = preview.loopbackEndpoint {
                LabeledContent(L10n.tr("Loopback")) {
                    Text(loopbackEndpoint)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let upstreamEndpoint = preview.upstreamEndpoint {
                LabeledContent(L10n.tr("Upstream")) {
                    Text(upstreamEndpoint)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            LabeledContent(L10n.tr("Model")) {
                Text(preview.model)
            }
            LabeledContent(L10n.tr("Codex model catalog")) {
                if let modelCatalogCount = preview.modelCatalogCount {
                    Text(verbatim: L10n.tr("Apply 時建立 %lld 個 models", modelCatalogCount))
                } else {
                    Text(verbatim: L10n.tr("Apply 時建立"))
                }
            }

            ForEach(preview.changes, id: \.self) { change in
                Label(change, systemImage: "arrow.right")
                    .font(.callout)
            }

            ForEach(preview.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            DisclosureGroup(L10n.tr("Projected config.toml（不含 API key）")) {
                TextEditor(text: .constant(preview.projectedConfig))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
                    .textSelection(.enabled)
            }
        }
    }
}
