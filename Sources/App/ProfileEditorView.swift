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

                LabeledContent("Endpoint") {
                    Text(appState.endpoint(for: draft.presetKey))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                TextField("Model", text: $draft.model)
                    .textFieldStyle(.roundedBorder)
                    .help("OpenCode Go MVP 僅支援原生 Responses model。")
            }

            Section("Credentials") {
                SecureField("New API key", text: $draft.apiKey)
                    .textFieldStyle(.roundedBorder)

                Text("只接受新的 API key；儲存成功後欄位會清空。既有 key 不會讀出或顯示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        .disabled(appState.isBusy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New Profile" : (draft.name.isEmpty ? "Profile" : draft.name))
        .onChange(of: draft.presetKey) { oldKey, newKey in
            if draft.model.isEmpty || draft.model == appState.defaultModel(for: oldKey) {
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
            LabeledContent("Endpoint") {
                Text(preview.endpoint)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
