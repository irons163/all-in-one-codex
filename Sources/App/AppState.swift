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

    struct ModelCatalogStatus: Equatable {
        enum State: Equatable {
            case pending
            case applied
            case restored
        }

        let state: State
        let modelCount: Int?
        let profileID: UUID?
        let model: String?

        static let pending = ModelCatalogStatus(
            state: .pending,
            modelCount: nil,
            profileID: nil,
            model: nil
        )

        static let restored = ModelCatalogStatus(
            state: .restored,
            modelCount: nil,
            profileID: nil,
            model: nil
        )

        var isApplied: Bool {
            state == .applied
        }

        func matches(profileID candidateProfileID: UUID?, model candidateModel: String) -> Bool {
            guard
                state == .applied,
                let profileID,
                let model
            else {
                return false
            }
            return profileID == candidateProfileID
                && model == candidateModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        var preserveSessions: Bool
        /// This is write-only from the UI's point of view.
        var apiKey: String

        init(
            id: UUID? = nil,
            name: String = "",
            presetKey: String = "",
            model: String = "",
            preserveSessions: Bool = false,
            apiKey: String = ""
        ) {
            self.id = id
            self.name = name
            self.presetKey = presetKey
            self.model = model
            self.preserveSessions = preserveSessions
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
        let modelCatalogCount: Int?
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
            modelCatalogCount: Int?,
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
            self.modelCatalogCount = modelCatalogCount
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
    @Published private(set) var restartRequired = false
    @Published private(set) var modelCatalogStatus = ModelCatalogStatus.pending
    @Published private(set) var restoreBackups: [CodexConfigurationBackup] = []
    @Published private(set) var receiptJournalEntries: [SwitchReceiptJournalEntry] = []
    @Published var errorMessage: String?
    @Published var selectedProfileID: UUID?
    @Published var editorDraft = ProfileDraft()
    @Published private(set) var isCreatingProfile = false
    @Published var isShowingNewProfile = false
    @Published var isShowingRestore = false

    // MARK: Core dependencies

    static let restartRequiredMessage =
        "設定與 model catalog 已更新；請完全退出並重新啟動 Codex App/CLI。"

    private let profileRepository: ProfileRepository
    private let credentialStore: any CredentialStoring
    private let clientAdapter: any ClientAdapter
    private let receiptRepository: SwitchReceiptRepository
    private var coreProfiles: [ProviderProfile] = []
    private var credentialAvailability: [UUID: Bool] = [:]
    private var lastReceipt: SwitchReceipt?
    private var hasLoadedProfiles = false

    init(
        profileRepository: ProfileRepository = ProfileRepository(),
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        clientAdapter: (any ClientAdapter)? = nil,
        receiptRepository: SwitchReceiptRepository = SwitchReceiptRepository()
    ) {
        self.profileRepository = profileRepository
        self.credentialStore = credentialStore
        self.receiptRepository = receiptRepository
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

    var canUndoLastSwitch: Bool {
        lastReceipt != nil || !receiptJournalEntries.isEmpty
    }

    var hasPersistentUndo: Bool {
        !receiptJournalEntries.isEmpty
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

    func modelCatalogCount(for presetKey: String, model: String) -> Int? {
        guard let presetID = corePresetID(for: presetKey) else {
            return nil
        }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return nil
        }

        do {
            let profile = ProviderProfile(
                name: "Catalog preview",
                presetID: presetID,
                model: trimmedModel
            )
            return try CodexModelCatalog.make(for: profile).models.count
        } catch {
            return nil
        }
    }

    func dismissRestartRequired() {
        restartRequired = false
        if statusMessage == Self.restartRequiredMessage {
            statusMessage = nil
        }
    }

    func isDefaultModel(_ model: String, for presetKey: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
            == defaultModel(for: presetKey)
    }

    func routePresentation(
        for presetKey: String,
        model: String,
        preserveSessions: Bool = false
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
                    model: trimmedModel,
                    preserveSessions: preserveSessions
                )
            )
            return makeRoutePresentation(
                for: route,
                preserveSessions: preserveSessions
            )
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
            preserveSessions: profile.preserveSessions,
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

    func beginRestore() {
        guard !isBusy else { return }
        isShowingRestore = true
        Task { [weak self] in
            await self?.refreshRestoreData()
        }
    }

    func cancelRestore() {
        isShowingRestore = false
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

        if let restoreError = await loadRestoreData() {
            let message = failureMessage("載入 config backups", error: restoreError)
            if let existingMessage = errorMessage, !existingMessage.isEmpty {
                errorMessage = "\(existingMessage)\n\(message)"
            } else {
                errorMessage = message
            }
        }
    }

    func refreshRestoreData() async {
        if let restoreError = await loadRestoreData() {
            fail("載入 config backups", error: restoreError)
        }
    }

    private func loadRestoreData() async -> Error? {
        receiptJournalEntries = await receiptRepository.load()

        guard let codexAdapter else {
            // Injected fakes and other ClientAdapter implementations do not
            // expose Codex backup inventory. Keep restore safely empty.
            restoreBackups = []
            return nil
        }

        do {
            restoreBackups = try codexAdapter.listConfigurationBackups()
            return nil
        } catch {
            restoreBackups = []
            return error
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

    func restore(_ backup: CodexConfigurationBackup) async {
        guard !isBusy else { return }
        guard let codexAdapter else {
            fail("Restore Backup", error: AppStateError.restoreUnavailable)
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let receipt = try codexAdapter.restoreConfigurationBackup(backup)
            lastReceipt = receipt
            activeProfileID = nil
            modelCatalogStatus = .restored
            restartRequired = true
            rebuildProfileItems()
            statusMessage = Self.restartRequiredMessage

            await persistReceipt(
                receipt,
                profileName: "Config backup restore",
                model: nil,
                providerDisplayName: nil
            )
            await refreshRestoreData()
            isShowingRestore = false
        } catch {
            fail("Restore Backup", error: error)
        }
    }

    func undoLastSwitch() async {
        guard !isBusy else { return }

        let persistedEntries = await receiptRepository.load()
        receiptJournalEntries = persistedEntries

        let receipt: SwitchReceipt
        let journalEntry: SwitchReceiptJournalEntry?
        if let lastReceipt {
            receipt = lastReceipt
            journalEntry = persistedEntries.first { $0.receipt == lastReceipt }
        } else if let newestEntry = persistedEntries.first {
            receipt = newestEntry.receipt
            journalEntry = newestEntry
        } else {
            fail("Undo")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            // Core integration point: adapt only this call if the final Core
            // method uses an unlabeled receipt argument.
            try clientAdapter.undo(receipt)
            self.lastReceipt = nil
            activeProfileID = nil
            rebuildProfileItems()
            modelCatalogStatus = .restored
            restartRequired = true
            statusMessage = "已復原上一個 switch；請完全退出並重新啟動 Codex App/CLI。"

            if let journalEntry {
                do {
                    try await receiptRepository.delete(journalEntry)
                } catch {
                    statusMessage =
                        "設定已復原，但 persistent Undo journal 無法更新；目前設定交易仍已完成。"
                }
            }
            await refreshRestoreData()
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
            let didWriteModelCatalog = receipt.catalogURL != nil
                && receipt.catalogAfterHash != nil
            modelCatalogStatus = ModelCatalogStatus(
                state: didWriteModelCatalog ? .applied : .pending,
                modelCount: didWriteModelCatalog
                    ? modelCatalogCount(
                        for: presetKey(for: profile.presetID),
                        model: profile.model
                    )
                    : nil,
                profileID: didWriteModelCatalog ? profile.id : nil,
                model: didWriteModelCatalog ? profile.model : nil
            )
            restartRequired = true
            rebuildProfileItems()
            statusMessage = Self.restartRequiredMessage
            await persistReceipt(receipt, profile: profile)
            await refreshRestoreData()
        } catch {
            fail("套用 profile", error: error)
        }
    }

    private func persistReceipt(_ receipt: SwitchReceipt, profile: ProviderProfile) async {
        do {
            try await receiptRepository.persist(receipt: receipt, profile: profile)
        } catch {
            statusMessage =
                "設定已套用，但 persistent Undo journal 無法寫入；本次仍可在目前執行期間 Undo。"
        }
    }

    private func persistReceipt(
        _ receipt: SwitchReceipt,
        profileName: String?,
        model: String?,
        providerDisplayName: String?
    ) async {
        do {
            try await receiptRepository.save(
                receipt: receipt,
                profileName: profileName,
                model: model,
                providerDisplayName: providerDisplayName,
                createdAt: receipt.timestamp
            )
        } catch {
            statusMessage =
                "設定已完成，但 persistent Undo journal 無法寫入；本次仍可在目前執行期間 Undo。"
        }
    }

    private var codexAdapter: CodexClientAdapter? {
        clientAdapter as? CodexClientAdapter
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
            preserveSessions: draft.preserveSessions,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
    }

    private func rebuildProfileItems() {
        profileItems = coreProfiles.map { profile in
            let presentation = presetPresentation(for: profile.presetID)
            let route = routePresentation(
                for: presetKey(for: profile.presetID),
                model: profile.model,
                preserveSessions: profile.preserveSessions
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
            model: profile.model,
            preserveSessions: profile.preserveSessions
        )
        var changes = [
            "更新 ~/.codex/config.toml",
            "切換 provider 為 \(presentation.name)",
            "使用 model \(profile.model)"
        ]
        let catalogModelCount = modelCatalogCount(
            for: presetKey(for: profile.presetID),
            model: profile.model
        )
        if let catalogModelCount {
            changes.append(
                "Apply 時建立 Codex model catalog（\(catalogModelCount) 個 models）"
            )
        }
        var warnings: [String] = []

        if profile.preserveSessions {
            changes.append("保留 Codex 內建 openai provider namespace，重啟後可重新開啟既有 sessions")
            changes.append("所有請求經本機 proxy，並由 Keychain 注入此 profile 的 API key")
            if let loopbackEndpoint = route.loopbackEndpoint {
                changes.append("Loopback endpoint：\(loopbackEndpoint)")
            }
            if let upstreamEndpoint = route.upstreamEndpoint {
                changes.append("Upstream endpoint：\(upstreamEndpoint)")
            }
            warnings.append("保留模式需要 All-in-One Codex 持續開啟，並在 Apply 後完全重新啟動 Codex。")
            warnings.append("正在執行中的 task 不會熱切換；請在重啟後重新開啟既有 task。")
        } else if route.bridgeEnabled {
            let bridgeLabel = route.bridgeStatus == .running
                ? "執行中"
                : "Apply 時自動啟動"
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
                warnings.append(
                    "Bridge 會在 Apply 時由 All-in-One Codex 自動啟動；不需另外手動啟動。"
                )
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
            modelCatalogCount: catalogModelCount,
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

    private func makeRoutePresentation(
        for route: ProviderRoute,
        preserveSessions: Bool
    ) -> RoutePresentation {
        if preserveSessions {
            let upstreamEndpoint = route.requiresLoopbackBridge
                ? Self.openCodeGoUpstreamEndpoint
                : route.baseURL
            return RoutePresentation(
                routeName: "Session-preserving local proxy",
                endpoint: OpenCodeGoBridgeManager.baseURL,
                explanation: "保留 Codex 內建 openai provider namespace；請求經本機 proxy 從 Keychain 取得 API key，再依 model 透明轉送或轉換。重啟後可重新開啟既有 task，使用期間請保持 All-in-One Codex 開啟。",
                bridgeEnabled: true,
                bridgeStatus: bridgeStatus,
                loopbackEndpoint: OpenCodeGoBridgeManager.baseURL,
                upstreamEndpoint: upstreamEndpoint,
                isKnown: true
            )
        }

        if route.requiresLoopbackBridge {
            let upstreamEndpoint = Self.openCodeGoUpstreamEndpoint
            return RoutePresentation(
                routeName: "Local Bridge → upstream Chat Completions",
                endpoint: route.baseURL,
                explanation: "Chat-only model 由本機 bridge 轉換 Responses ↔ Chat Completions；Apply 會自動啟動 bridge，使用期間請保持 All-in-One Codex 開啟。",
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
        if let friendlyMessage = friendlyCoreErrorMessage(error) {
            return "\(operation) 失敗：\(friendlyMessage)"
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty
        {
            return "\(operation) 失敗：\(description)"
        } else {
            return "\(operation) 失敗。請檢查 Core adapter 與設定。"
        }
    }

    private func friendlyCoreErrorMessage(_ error: Error?) -> String? {
        guard let error else {
            return nil
        }

        if let catalogError = error as? CodexModelCatalogError {
            switch catalogError {
            case .emptyModels:
                return "Codex model catalog 不可為空。"
            case .tooManyModels:
                return "Codex model catalog 的 model 數量超過安全上限。"
            case .duplicateModel:
                return "Codex model catalog 含有重複 model。"
            case .invalidModelIdentifier:
                return "選取的 model ID 無法安全寫入 Codex model catalog。"
            case .invalidSchema:
                return "Codex model catalog 格式不受支援。"
            case .catalogTooLarge:
                return "Codex model catalog 太大，未套用設定。"
            case .unreadableCatalog:
                return "Codex model catalog 無法安全讀取。"
            case .unsafeCatalogPath:
                return "Codex model catalog 路徑不安全，為保護現有設定未覆寫。"
            }
        }

        if let switchError = error as? CodexSwitchError {
            switch switchError {
            case .invalidProfile:
                return "選取的 profile 不完整，未修改 Codex 設定。"
            case .malformedManagedMarkers:
                return "Codex 設定的 managed 區塊不完整，為安全起見未覆寫。"
            case .misplacedActiveMarker:
                return "Codex 設定的 managed active 區塊位置不安全，未覆寫。"
            case .missingCredential:
                return "尚未找到此 profile 的 API key，請先在 Credentials 設定。"
            case .unreadableConfiguration:
                return "Codex 設定無法安全讀取，未覆寫現有檔案。"
            case .unableToWriteConfiguration:
                return "Codex 設定無法安全寫入，可能已回復原狀。"
            case .backupUnavailable:
                return "找不到可用的 config backup，請重新整理清單。"
            case .backupIntegrityConflict:
                return "config backup 與記錄狀態不一致，為安全起見未復原。"
            case .configurationChanged:
                return "Codex 設定在交易後已變更，為安全起見無法 Undo。"
            case .modelCatalogChanged:
                return "Codex model catalog 在套用後已變更，為安全起見無法 Undo。"
            case .foreignModelCatalogPointer:
                return "現有 Codex 設定指向其他 model catalog；為安全起見未覆寫，請先移除或改回該設定。"
            case .foreignOpenAIBaseURL:
                return "現有 Codex 設定已包含非本 App 管理的 openai_base_url；為避免誤送請求，請先移除或改回該設定。"
            case .unsafeBackupPath:
                return "config backup 路徑不安全，為保護現有設定未覆寫。"
            case .invalidConfigurationBackup:
                return "選取的 config backup 不是可讀的 TOML，未覆寫現有設定。"
            case .configurationBackupTooLarge:
                return "選取的 config backup 超過安全大小上限，未覆寫現有設定。"
            }
        }

        if let repositoryError = error as? SwitchReceiptRepositoryError {
            switch repositoryError {
            case .unableToWriteJournal:
                return "persistent Undo journal 無法寫入；設定交易本身仍可安全完成。"
            case .unableToDeleteJournal:
                return "persistent Undo journal 無法更新。"
            }
        }

        return nil
    }

    private enum AppStateError: LocalizedError {
        case invalidName
        case invalidProvider
        case invalidModel
        case missingCredential
        case restoreUnavailable

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
            case .restoreUnavailable:
                return "目前的 client adapter 不支援 Codex config backup restore。"
            }
        }
    }
}
