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
        let requiresLoopbackBridge: Bool
        let bridgeStatus: OpenCodeGoBridgeStatus?
    }

    struct ModelOption: Identifiable, Equatable {
        enum Transport: String, Equatable {
            case responses
            case chatCompletions

            var label: String {
                switch self {
                case .responses:
                    return "Responses"
                case .chatCompletions:
                    return "Chat Completions → 本機 bridge"
                }
            }
        }

        let id: String
        let modelID: String
        let transport: Transport

        var isChatOnly: Bool {
            transport == .chatCompletions
        }
    }

    struct PresetOption: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: String
        let defaultModel: String
        let models: [ModelOption]
        let allowsCustomModels: Bool
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

    enum CredentialStatus: Equatable {
        case missing
        case saved
        case newValue
    }

    struct PreviewSnapshot: Identifiable, Equatable {
        let id: UUID
        let profileID: UUID
        let profileName: String
        let providerName: String
        let endpoint: String
        let routeName: String
        let bridgeEnabled: Bool
        let bridgeStatus: OpenCodeGoBridgeStatus?
        let loopbackEndpoint: String?
        let upstreamEndpoint: String?
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
            routeName: String,
            bridgeEnabled: Bool,
            bridgeStatus: OpenCodeGoBridgeStatus?,
            loopbackEndpoint: String?,
            upstreamEndpoint: String?,
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
            self.routeName = routeName
            self.bridgeEnabled = bridgeEnabled
            self.bridgeStatus = bridgeStatus
            self.loopbackEndpoint = loopbackEndpoint
            self.upstreamEndpoint = upstreamEndpoint
            self.model = model
            self.summary = summary
            self.projectedConfig = projectedConfig
            self.changes = changes
            self.warnings = warnings
        }
    }

    struct RoutePresentation: Equatable {
        let routeName: String
        let endpoint: String
        let explanation: String
        let bridgeEnabled: Bool
        let bridgeStatus: OpenCodeGoBridgeStatus?
        let loopbackEndpoint: String?
        let upstreamEndpoint: String?
        let isKnown: Bool
    }

    @Published private(set) var profileItems: [ProfileListItem] = []
    @Published private(set) var presetOptions: [PresetOption]
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var preview: PreviewSnapshot?
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var bridgeStatus: OpenCodeGoBridgeStatus = .stopped
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
    private var credentialAvailability: [UUID: Bool] = [:]
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

    var editorCredentialStatus: CredentialStatus {
        if !editorDraft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .newValue
        }
        guard let profileID = editorDraft.id,
              credentialAvailability[profileID] == true
        else {
            return .missing
        }
        return .saved
    }

    func endpoint(for presetKey: String, model: String) -> String {
        routePresentation(for: presetKey, model: model).endpoint
    }

    func providerName(for presetKey: String) -> String {
        presetOptions.first { $0.id == presetKey }?.name
            ?? "未選擇 provider"
    }

    func defaultModel(for presetKey: String) -> String {
        presetOptions.first { $0.id == presetKey }?.defaultModel ?? ""
    }

    func modelOptions(for presetKey: String) -> [ModelOption] {
        presetOptions.first { $0.id == presetKey }?.models ?? []
    }

    func allowsCustomModels(for presetKey: String) -> Bool {
        presetOptions.first { $0.id == presetKey }?.allowsCustomModels ?? false
    }

    func isDefaultModel(_ model: String, for presetKey: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
            == defaultModel(for: presetKey)
    }

    func routePresentation(
        for presetKey: String,
        model: String
    ) -> RoutePresentation {
        let fallbackEndpoint = presetOptions.first { $0.id == presetKey }?.endpoint
            ?? Self.fallbackEndpoint(for: presetKey)
        guard let presetID = corePresetID(for: presetKey) else {
            return unavailableRoute(
                endpoint: fallbackEndpoint,
                explanation: "Provider preset 無效，無法判定 route。"
            )
        }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return unavailableRoute(
                endpoint: fallbackEndpoint,
                explanation: "請輸入或選擇 model，才能判定 route。"
            )
        }

        do {
            let route = try ProviderCatalog.route(
                for: ProviderProfile(
                    name: "Route preview",
                    presetID: presetID,
                    model: trimmedModel
                )
            )
            return makeRoutePresentation(for: route)
        } catch let error as ProviderRoutingError {
            return unavailableRoute(
                endpoint: fallbackEndpoint,
                explanation: routingExplanation(for: error)
            )
        } catch {
            return unavailableRoute(
                endpoint: fallbackEndpoint,
                explanation: "Core 無法判定此 model 的 route。"
            )
        }
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
        refreshCredentialAvailability(for: profile.id)
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

        var preparationError: Error?
        do {
            // Core decides whether the existing active configuration needs
            // the bridge. A startup failure must not prevent profile metadata
            // from being loaded below.
            try clientAdapter.prepareForUse()
            bridgeStatus = clientAdapter.bridgeStatus
        } catch {
            bridgeStatus = clientAdapter.bridgeStatus
            preparationError = error
        }

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
            if let preparationError {
                errorMessage = failureMessage(
                    "啟動 OpenCode Go bridge",
                    error: preparationError
                )
            }
        } catch {
            coreProfiles = []
            rebuildProfileItems()
            statusMessage = nil
            let failures = [
                preparationError.map {
                    failureMessage("啟動 OpenCode Go bridge", error: $0)
                },
                failureMessage("載入 profiles", error: error)
            ]
            errorMessage = failures.compactMap { $0 }.joined(separator: "\n")
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
            if hasCredentialInput(draft.apiKey) {
                try credentialStore.save(
                    Data(draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                    for: profile.id
                )
                credentialWasStored = true
            }

            // Core integration point: adapt only this call if save is sync.
            try await profileRepository.save(updatedProfiles)
            coreProfiles = updatedProfiles
            let hasCredential = credentialWasStored || credentialStore.contains(for: profile.id)
            credentialAvailability[profile.id] = hasCredential
            selectedProfileID = profile.id
            isCreatingProfile = false
            isShowingNewProfile = false
            editorDraft.apiKey = ""
            rebuildProfileItems()
            prepareEditorForSelection()
            preview = nil
            statusMessage = hasCredential
                ? "Profile 已儲存。"
                : "Profile 已儲存，但尚未設定 API key。"
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
        preview = nil

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
            guard ensureCredentialForApply(
                profileID: selectedProfileID,
                pendingCredential: editorDraft.apiKey
            ) else {
                return
            }
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

        guard credentialStore.contains(for: profile.id) else {
            credentialAvailability[profile.id] = false
            fail("套用 profile", error: AppStateError.missingCredential)
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            // Core integration point: this is the sole apply call.
            let receipt = try clientAdapter.apply(profile: profile)
            lastReceipt = receipt
            bridgeStatus = clientAdapter.bridgeStatus
            activeProfileID = profileID
            rebuildProfileItems()
            statusMessage = "已套用「\(profile.name)」。"
        } catch {
            fail("套用 profile", error: error)
        }
    }

    private func ensureCredentialForApply(
        profileID: UUID,
        pendingCredential: String
    ) -> Bool {
        if hasCredentialInput(pendingCredential) {
            return true
        }

        let hasCredential = credentialStore.contains(for: profileID)
        credentialAvailability[profileID] = hasCredential
        guard hasCredential else {
            statusMessage = "尚未設定 API key。"
            fail(
                "套用 profile",
                error: AppStateError.missingCredential
            )
            return false
        }
        return true
    }

    private func refreshCredentialAvailability(for profileID: UUID) {
        credentialAvailability[profileID] = credentialStore.contains(for: profileID)
    }

    private func hasCredentialInput(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            let route = routePresentation(
                for: presetKey(for: profile.presetID),
                model: profile.model
            )
            return ProfileListItem(
                id: profile.id,
                name: profile.name,
                providerName: presentation.name,
                model: profile.model,
                isActive: profile.id == activeProfileID,
                requiresLoopbackBridge: route.bridgeEnabled,
                bridgeStatus: route.bridgeStatus
            )
        }
    }

    private func makePreviewSnapshot(
        for profile: ProviderProfile,
        corePreview: SwitchPreview
    ) -> PreviewSnapshot {
        let presentation = presetPresentation(for: profile.presetID)
        let route = routePresentation(
            for: presetKey(for: profile.presetID),
            model: profile.model
        )
        var changes = [
            "更新 ~/.codex/config.toml",
            "切換 provider 為 \(presentation.name)",
            "使用 model \(profile.model)"
        ]
        var warnings: [String] = []

        if route.bridgeEnabled {
            let bridgeLabel = route.bridgeStatus == .running ? "執行中" : "未啟動"
            changes.append(
                "Bridge：\(bridgeLabel)（本機 Responses ↔ Chat Completions 轉換）"
            )
            if let loopbackEndpoint = route.loopbackEndpoint {
                changes.append("Loopback endpoint：\(loopbackEndpoint)")
            }
            if let upstreamEndpoint = route.upstreamEndpoint {
                changes.append("Upstream endpoint：\(upstreamEndpoint)")
            }
            if route.bridgeStatus != .running {
                warnings.append("Bridge 尚未執行；套用後請保持 All-in-One Codex 開啟。")
            }
        } else {
            changes.append("Bridge：未啟用（直接使用 Responses）")
            changes.append("Endpoint：\(route.endpoint)")
        }

        return PreviewSnapshot(
            profileID: profile.id,
            profileName: profile.name,
            providerName: presentation.name,
            endpoint: route.endpoint,
            routeName: route.routeName,
            bridgeEnabled: route.bridgeEnabled,
            bridgeStatus: route.bridgeStatus,
            loopbackEndpoint: route.loopbackEndpoint,
            upstreamEndpoint: route.upstreamEndpoint,
            model: profile.model,
            summary: corePreview.summary,
            projectedConfig: corePreview.projected,
            changes: changes,
            warnings: warnings
        )
    }

    private func makeEmptyDraft() -> ProfileDraft {
        let firstPreset = presetOptions.first
        return ProfileDraft(
            presetKey: firstPreset?.id ?? "",
            model: firstPreset?.defaultModel ?? ""
        )
    }

    private func presetKey(for presetID: ProviderPresetID) -> String {
        presetID.rawValue
    }

    private func corePresetID(for key: String) -> ProviderPresetID? {
        ProviderCatalog.all.first {
            $0.id.rawValue == key || String(describing: $0.id) == key
        }?.id
    }

    private func presetPresentation(
        for presetID: ProviderPresetID
    ) -> (name: String, endpoint: String) {
        let key = presetID.rawValue
        guard let preset = ProviderCatalog.preset(for: presetID) else {
            return (
                Self.fallbackName(for: key),
                Self.fallbackEndpoint(for: key)
            )
        }
        return (
            preset.displayName,
            preset.baseURL
        )
    }

    private static func buildPresetOptions() -> [PresetOption] {
        ProviderCatalog.all.map { preset in
            let descriptorModels = preset.modelDescriptors.compactMap { descriptor -> ModelOption? in
                switch descriptor.wireAPI {
                case .responses:
                    return ModelOption(
                        id: descriptor.modelID,
                        modelID: descriptor.modelID,
                        transport: .responses
                    )
                case .chatCompletions:
                    return ModelOption(
                        id: descriptor.modelID,
                        modelID: descriptor.modelID,
                        transport: .chatCompletions
                    )
                case .anthropicMessages:
                    // Messages models remain unsupported and are not offered
                    // as selectable UI options.
                    return nil
                }
            }
            let models = descriptorModels.isEmpty
                ? [
                    ModelOption(
                        id: preset.defaultModel,
                        modelID: preset.defaultModel,
                        transport: .responses
                    )
                ]
                : descriptorModels
            return PresetOption(
                id: preset.id.rawValue,
                name: preset.displayName,
                endpoint: preset.baseURL,
                defaultModel: preset.defaultModel,
                models: models,
                allowsCustomModels: preset.allowsCustomModels
            )
        }
        .sorted { $0.name < $1.name }
    }

    private func makeRoutePresentation(for route: ProviderRoute) -> RoutePresentation {
        if route.requiresLoopbackBridge {
            let upstreamEndpoint = Self.openCodeGoUpstreamEndpoint
            return RoutePresentation(
                routeName: "Local Bridge → upstream Chat Completions",
                endpoint: route.baseURL,
                explanation: "Chat-only model 由本機 bridge 轉換 Responses ↔ Chat Completions；app 需保持執行。",
                bridgeEnabled: true,
                bridgeStatus: bridgeStatus,
                loopbackEndpoint: route.baseURL,
                upstreamEndpoint: upstreamEndpoint,
                isKnown: true
            )
        }

        return RoutePresentation(
            routeName: "Direct Responses",
            endpoint: route.baseURL,
            explanation: "Codex 直接使用 provider 的 Responses endpoint。",
            bridgeEnabled: false,
            bridgeStatus: nil,
            loopbackEndpoint: nil,
            upstreamEndpoint: nil,
            isKnown: true
        )
    }

    private func unavailableRoute(
        endpoint: String,
        explanation: String
    ) -> RoutePresentation {
        RoutePresentation(
            routeName: "Route unavailable",
            endpoint: endpoint,
            explanation: explanation,
            bridgeEnabled: false,
            bridgeStatus: nil,
            loopbackEndpoint: nil,
            upstreamEndpoint: nil,
            isKnown: false
        )
    }

    private func routingExplanation(for error: ProviderRoutingError) -> String {
        switch error {
        case .invalidModel:
            return "Model 不可為空。"
        case .unknownOpenCodeGoModel:
            return "此 OpenCode Go model 不在支援清單內；Core 會拒絕此設定。"
        case .unsupportedOpenCodeGoWireAPI(.anthropicMessages):
            return "此 model 使用 Anthropic Messages API，目前尚未支援；Core 會拒絕此設定。"
        case .unsupportedOpenCodeGoWireAPI:
            return "此 OpenCode Go model 使用目前不支援的 provider API；Core 會拒絕此設定。"
        }
    }

    private static var openCodeGoUpstreamEndpoint: String {
        "\(ProviderCatalog.openCodeGoOfficialBaseURL)/chat/completions"
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
            return "https://opencode.ai/zen/go/v1"
        }
        if normalized.contains("openrouter") {
            return "https://openrouter.ai/api/v1"
        }
        return "由 Core preset 提供"
    }

    private func fail(_ operation: String, error: Error? = nil) {
        errorMessage = failureMessage(operation, error: error)
    }

    private func failureMessage(_ operation: String, error: Error? = nil) -> String {
        // Core's typed errors intentionally omit credential contents. Unknown
        // errors remain generic so provider request details cannot leak into
        // the UI.
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty
        {
            return "\(operation) 失敗：\(description)"
        } else {
            return "\(operation) 失敗。請檢查 Core adapter 與設定。"
        }
    }

    private enum AppStateError: LocalizedError {
        case invalidName
        case invalidProvider
        case invalidModel
        case missingCredential

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Profile 名稱不可為空。"
            case .invalidProvider:
                return "Provider preset 無效。"
            case .invalidModel:
                return "Model 不可為空。"
            case .missingCredential:
                return "尚未設定 API key。請先在 Credentials 輸入 API key。"
            }
        }
    }
}
