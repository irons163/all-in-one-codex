import Combine
import Foundation

/// The app-facing state model.
///
/// Core integration is intentionally kept in this file. SwiftUI views only
/// consume the small presentation models below, so a final Core async or
/// argument-label change has one integration boundary to update.
@MainActor
final class AppState: ObservableObject {
    struct ProfileListItem: Identifiable, Equatable {
        let id: UUID
        let name: String
        let providerName: String
        let model: String
        let isActive: Bool
    }

    struct PresetOption: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: String
        let models: [String]
    }

    struct ProfileDraft: Equatable {
        var id: UUID?
        var name: String
        var presetKey: String
        var model: String
        /// This is write-only from the UI's point of view.
        var apiKey: String

        init(
            id: UUID? = nil,
            name: String = "",
            presetKey: String = "",
            model: String = "",
            apiKey: String = ""
        ) {
            self.id = id
            self.name = name
            self.presetKey = presetKey
            self.model = model
            self.apiKey = apiKey
        }
    }

    struct PreviewSnapshot: Identifiable, Equatable {
        let id: UUID
        let profileID: UUID
        let profileName: String
        let providerName: String
        let endpoint: String
        let model: String
        let summary: String
        let projectedConfig: String
        let changes: [String]
        let warnings: [String]

        init(
            profileID: UUID,
            profileName: String,
            providerName: String,
            endpoint: String,
            model: String,
            summary: String,
            projectedConfig: String,
            changes: [String],
            warnings: [String]
        ) {
            self.id = UUID()
            self.profileID = profileID
            self.profileName = profileName
            self.providerName = providerName
            self.endpoint = endpoint
            self.model = model
            self.summary = summary
            self.projectedConfig = projectedConfig
            self.changes = changes
            self.warnings = warnings
        }
    }

    @Published private(set) var profileItems: [ProfileListItem] = []
    @Published private(set) var presetOptions: [PresetOption]
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var preview: PreviewSnapshot?
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?
    @Published var selectedProfileID: UUID?
    @Published var editorDraft = ProfileDraft()
    @Published private(set) var isCreatingProfile = false
    @Published var isShowingNewProfile = false

    // MARK: Core dependencies

    private let profileRepository: ProfileRepository
    private let credentialStore: any CredentialStoring
    private let clientAdapter: any ClientAdapter
    private var coreProfiles: [ProviderProfile] = []
    private var lastReceipt: SwitchReceipt?
    private var hasLoadedProfiles = false

    init(
        profileRepository: ProfileRepository = ProfileRepository(),
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        clientAdapter: (any ClientAdapter)? = nil
    ) {
        self.profileRepository = profileRepository
        self.credentialStore = credentialStore
        self.clientAdapter = clientAdapter
            ?? CodexClientAdapter(credentialStore: credentialStore)
        self.presetOptions = Self.buildPresetOptions()

        Task { [weak self] in
            await self?.loadProfiles()
        }
    }

    // MARK: Presentation helpers

    var selectedProfileItem: ProfileListItem? {
        guard let selectedProfileID else { return nil }
        return profileItems.first { $0.id == selectedProfileID }
    }

    func endpoint(for presetKey: String) -> String {
        presetOptions.first { $0.id == presetKey }?.endpoint
            ?? "由 Core preset 提供"
    }

    func providerName(for presetKey: String) -> String {
        presetOptions.first { $0.id == presetKey }?.name
            ?? "未選擇 provider"
    }

    func defaultModel(for presetKey: String) -> String {
        presetOptions.first { $0.id == presetKey }?.models.first ?? ""
    }

    func prepareEditorForSelection() {
        guard
            let selectedProfileID,
            let profile = coreProfiles.first(where: { $0.id == selectedProfileID })
        else {
            if !isCreatingProfile {
                editorDraft = makeEmptyDraft()
            }
            preview = nil
            return
        }

        isCreatingProfile = false
        editorDraft = ProfileDraft(
            id: profile.id,
            name: profile.name,
            presetKey: presetKey(for: profile.presetID),
            model: profile.model,
            apiKey: ""
        )
        preview = nil
    }

    func beginCreatingProfile() {
        isCreatingProfile = true
        isShowingNewProfile = true
        editorDraft = makeEmptyDraft()
        preview = nil
        errorMessage = nil
    }

    func cancelCreatingProfile() {
        editorDraft.apiKey = ""
        isShowingNewProfile = false
        if isCreatingProfile {
            isCreatingProfile = false
            prepareEditorForSelection()
        }
    }

    // MARK: Persistence

    func loadProfiles() async {
        guard !hasLoadedProfiles else { return }
        hasLoadedProfiles = true
        isBusy = true
        defer { isBusy = false }

        do {
            // Core integration point: adapt only this call if load is sync.
            coreProfiles = try await profileRepository.load()
            rebuildProfileItems()
            if selectedProfileID == nil {
                selectedProfileID = coreProfiles.first?.id
            }
            prepareEditorForSelection()
            statusMessage = coreProfiles.isEmpty
                ? "尚未建立 profile。"
                : "已載入 \(coreProfiles.count) 個 profile。"
        } catch {
            coreProfiles = []
            rebuildProfileItems()
            statusMessage = nil
            fail("載入 profiles", error: error)
        }
    }

    @discardableResult
    func saveEditor() async -> UUID? {
        let draft = editorDraft
        let existing = draft.id.flatMap { id in
            coreProfiles.first { $0.id == id }
        }
        var credentialWasStored = false

        isBusy = true
        defer { isBusy = false }

        do {
            let profile = try makeCoreProfile(from: draft, existing: existing)
            var updatedProfiles = coreProfiles

            if let index = updatedProfiles.firstIndex(where: { $0.id == profile.id }) {
                updatedProfiles[index] = profile
            } else {
                updatedProfiles.append(profile)
            }

            // Never load or display an existing credential. A non-empty value
            // here is always a newly entered value from SecureField.
            if !draft.apiKey.isEmpty {
                try credentialStore.save(
                    Data(draft.apiKey.utf8),
                    for: profile.id
                )
                credentialWasStored = true
            }

            // Core integration point: adapt only this call if save is sync.
            try await profileRepository.save(updatedProfiles)
            coreProfiles = updatedProfiles
            selectedProfileID = profile.id
            isCreatingProfile = false
            isShowingNewProfile = false
            editorDraft.apiKey = ""
            rebuildProfileItems()
            prepareEditorForSelection()
            preview = nil
            statusMessage = "Profile 已儲存。"
            return profile.id
        } catch {
            // Do not retain a credential after it has been handed to Core.
            if credentialWasStored {
                editorDraft.apiKey = ""
            }
            fail("儲存 profile", error: error)
            return nil
        }
    }

    // MARK: Switching

    func previewEditor() async {
        let draft = editorDraft
        let existing = draft.id.flatMap { id in
            coreProfiles.first { $0.id == id }
        }

        do {
            let profile = try makeCoreProfile(from: draft, existing: existing)

            // Core integration point: this is the sole preview call.
            let corePreview = try clientAdapter.preview(profile: profile)
            preview = makePreviewSnapshot(for: profile, corePreview: corePreview)
            statusMessage = "Preview 已準備完成，尚未修改設定。"
        } catch {
            fail("Preview", error: error)
        }
    }

    func applySelectedProfile() async {
        guard let selectedProfileID else {
            fail("套用 profile")
            return
        }

        // Apply the current editor values when the detail editor belongs to
        // the selected persisted profile. Quick apply uses the single entry
        // point below and never bypasses AppState.
        if editorDraft.id == selectedProfileID, !isCreatingProfile {
            guard let savedID = await saveEditor() else { return }
            await applyProfile(profileID: savedID)
        } else {
            await applyProfile(profileID: selectedProfileID)
        }
    }

    func quickApply(profileID: UUID) async {
        await applyProfile(profileID: profileID)
    }

    func undoLastSwitch() async {
        guard let lastReceipt else {
            fail("Undo")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            // Core integration point: adapt only this call if the final Core
            // method uses an unlabeled receipt argument.
            try clientAdapter.undo(lastReceipt)
            self.lastReceipt = nil
            activeProfileID = nil
            rebuildProfileItems()
            statusMessage = "已復原上一個 switch。"
        } catch {
            fail("Undo", error: error)
        }
    }

    // MARK: Core conversion

    private func applyProfile(profileID: UUID) async {
        guard let profile = coreProfiles.first(where: { $0.id == profileID }) else {
            fail("套用 profile")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            // Core integration point: this is the sole apply call.
            let receipt = try clientAdapter.apply(profile: profile)
            lastReceipt = receipt
            activeProfileID = profileID
            rebuildProfileItems()
            statusMessage = "已套用「\(profile.name)」。"
        } catch {
            fail("套用 profile", error: error)
        }
    }

    private func makeCoreProfile(
        from draft: ProfileDraft,
        existing: ProviderProfile?
    ) throws -> ProviderProfile {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppStateError.invalidName }

        guard let presetID = corePresetID(for: draft.presetKey) else {
            throw AppStateError.invalidProvider
        }

        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AppStateError.invalidModel }

        let now = Date()
        return ProviderProfile(
            id: existing?.id ?? UUID(),
            name: name,
            presetID: presetID,
            model: model,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
    }

    private func rebuildProfileItems() {
        profileItems = coreProfiles.map { profile in
            let presentation = presetPresentation(for: profile.presetID)
            return ProfileListItem(
                id: profile.id,
                name: profile.name,
                providerName: presentation.name,
                model: profile.model,
                isActive: profile.id == activeProfileID
            )
        }
    }

    private func makePreviewSnapshot(
        for profile: ProviderProfile,
        corePreview: SwitchPreview
    ) -> PreviewSnapshot {
        let presentation = presetPresentation(for: profile.presetID)
        var warnings: [String] = []

        if presentation.name.localizedCaseInsensitiveContains("opencode") {
            warnings.append("OpenCode Go MVP 僅支援原生 Responses model。")
        }

        return PreviewSnapshot(
            profileID: profile.id,
            profileName: profile.name,
            providerName: presentation.name,
            endpoint: presentation.endpoint,
            model: profile.model,
            summary: corePreview.summary,
            projectedConfig: corePreview.projected,
            changes: [
                "更新 ~/.codex/config.toml",
                "切換 provider 為 \(presentation.name)",
                "使用 model \(profile.model)"
            ],
            warnings: warnings
        )
    }

    private func makeEmptyDraft() -> ProfileDraft {
        let firstPreset = presetOptions.first
        return ProfileDraft(
            presetKey: firstPreset?.id ?? "",
            model: firstPreset?.models.first ?? ""
        )
    }

    private func presetKey(for presetID: ProviderPresetID) -> String {
        String(describing: presetID)
    }

    private func corePresetID(for key: String) -> ProviderPresetID? {
        ProviderCatalog.all.first { String(describing: $0.id) == key }?.id
    }

    private func presetPresentation(
        for presetID: ProviderPresetID
    ) -> (name: String, endpoint: String, models: [String]) {
        let key = String(describing: presetID)
        guard let preset = ProviderCatalog.preset(for: presetID) else {
            return (
                Self.fallbackName(for: key),
                Self.fallbackEndpoint(for: key),
                []
            )
        }
        return (
            preset.displayName,
            preset.baseURL,
            [preset.defaultModel]
        )
    }

    private static func buildPresetOptions() -> [PresetOption] {
        ProviderCatalog.all.map { preset in
            return PresetOption(
                id: String(describing: preset.id),
                name: preset.displayName,
                endpoint: preset.baseURL,
                models: [preset.defaultModel]
            )
        }
        .sorted { $0.name < $1.name }
    }

    private static func fallbackName(for key: String) -> String {
        let normalized = key.lowercased()
        if normalized.contains("opencode") {
            return "OpenCode Go"
        }
        if normalized.contains("openrouter") {
            return "OpenRouter"
        }
        return key
    }

    private static func fallbackEndpoint(for key: String) -> String {
        let normalized = key.lowercased()
        if normalized.contains("opencode") {
            return "https://opencode.ai/zen/v1"
        }
        if normalized.contains("openrouter") {
            return "https://openrouter.ai/api/v1"
        }
        return "由 Core preset 提供"
    }

    private func fail(_ operation: String, error: Error? = nil) {
        // Core's typed errors intentionally omit credential contents. Unknown
        // errors remain generic so provider request details cannot leak into
        // the UI.
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty
        {
            errorMessage = "\(operation) 失敗：\(description)"
        } else {
            errorMessage = "\(operation) 失敗。請檢查 Core adapter 與設定。"
        }
    }

    private enum AppStateError: LocalizedError {
        case invalidName
        case invalidProvider
        case invalidModel

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Profile 名稱不可為空。"
            case .invalidProvider:
                return "Provider preset 無效。"
            case .invalidModel:
                return "Model 不可為空。"
            }
        }
    }
}
