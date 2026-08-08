import SwiftUI

struct ProfileEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var draft: AppState.ProfileDraft
    let isNew: Bool

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Provider") {
                Picker("Provider", selection: $draft.presetKey) {
                    ForEach(appState.presetOptions) { option in
                        Text(option.name)
                            .tag(option.id)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("Model", text: $draft.model)
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
                            Text("OpenRouter 允許直接輸入自訂 model ID")
                        }
                    } label: {
                        Label("選擇 model", systemImage: "chevron.up.chevron.down")
                    }
                    .fixedSize()
                    .help("從 preset 的 model catalog 選擇；仍可直接輸入文字。")
                }

                LabeledContent("Route") {
                    Text(route.routeName)
                        .foregroundStyle(route.isKnown ? Color.primary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }

                if route.bridgeEnabled,
                   let bridgeStatus = route.bridgeStatus
                {
                    LabeledContent("Bridge") {
                        BridgeStatusBadge(status: bridgeStatus)
                    }
                }

                LabeledContent("Endpoint") {
                    Text(route.endpoint)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                if let loopbackEndpoint = route.loopbackEndpoint {
                    LabeledContent("Loopback") {
                        Text(loopbackEndpoint)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let upstreamEndpoint = route.upstreamEndpoint {
                    LabeledContent("Upstream") {
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

                if !route.isKnown {
                    Label(
                        "Core 會拒絕這個 model；請從清單選擇支援項目或修正輸入。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Credentials") {
                SecureField("New API key", text: $draft.apiKey)
                    .textFieldStyle(.roundedBorder)

                Text("只接受新的 API key；儲存成功後欄位會清空。既有 key 不會讀出或顯示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch appState.editorCredentialStatus {
                case .missing:
                    Label(
                        "尚未設定 API key；Apply 前請先輸入。",
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
                        Text("API key 已儲存；輸入新值可替換。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .newValue:
                    Label(
                        "新的 API key 將在 Save 或 Apply 時儲存。",
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
                        Button("Cancel") {
                            appState.cancelCreatingProfile()
                        }
                    }

                    Spacer()

                    Button {
                        Task { await appState.previewEditor() }
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .disabled(appState.isBusy || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task { await appState.saveEditor() }
                    } label: {
                        Label("Save Profile", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isBusy)

                    if !isNew {
                        Button {
                            Task { await appState.applySelectedProfile() }
                        } label: {
                            Label("Apply", systemImage: "checkmark.circle")
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
        .navigationTitle(isNew ? "New Profile" : (draft.name.isEmpty ? "Profile" : draft.name))
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
            model: draft.model
        )
    }
}

private struct PreviewSection: View {
    let preview: AppState.PreviewSnapshot

    var body: some View {
        Section("Preview") {
            Text(preview.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("Profile") {
                Text(preview.profileName)
            }
            LabeledContent("Provider") {
                Text(preview.providerName)
            }
            LabeledContent("Route") {
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
                LabeledContent("Bridge") {
                    BridgeStatusBadge(status: bridgeStatus)
                }
            }
            LabeledContent("Endpoint") {
                Text(preview.endpoint)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let loopbackEndpoint = preview.loopbackEndpoint {
                LabeledContent("Loopback") {
                    Text(loopbackEndpoint)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let upstreamEndpoint = preview.upstreamEndpoint {
                LabeledContent("Upstream") {
                    Text(upstreamEndpoint)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Model") {
                Text(preview.model)
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

            DisclosureGroup("Projected config.toml") {
                TextEditor(text: .constant(preview.projectedConfig))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
                    .textSelection(.enabled)
            }
        }
    }
}
