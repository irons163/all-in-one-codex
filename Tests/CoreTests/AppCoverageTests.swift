import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import AllInOneCodex

@MainActor
final class AppCoverageTests: XCTestCase {
    func testAppStateCoversEditorPreviewApplyUndoRestoreAndRoutes() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let credentials = InMemoryAppCredentialStore()
        let bridge = CoverageBridgeManager()
        bridge.statusValue = .running
        let adapter = CodexClientAdapter(
            configURL: directoryURL
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("config.toml"),
            credentialStore: credentials,
            bridgeManager: bridge
        )
        let state = AppState(
            profileRepository: ProfileRepository(
                storageURL: directoryURL.appendingPathComponent("profiles.json")
            ),
            credentialStore: credentials,
            clientAdapter: adapter,
            receiptRepository: SwitchReceiptRepository(
                storageURL: directoryURL.appendingPathComponent("switch-receipts.json")
            )
        )

        await waitUntilLoaded(state)
        XCTAssertEqual(state.statusMessage, L10n.tr("尚未建立 profile。"))
        XCTAssertFalse(state.canUndoLastSwitch)
        XCTAssertFalse(state.hasPersistentUndo)
        XCTAssertNil(state.selectedProfileItem)
        XCTAssertEqual(state.editorCredentialStatus, .missing)

        XCTAssertFalse(state.providerName(for: "missing").isEmpty)
        XCTAssertEqual(state.defaultModel(for: "missing"), "")
        XCTAssertTrue(state.modelOptions(for: "missing").isEmpty)
        XCTAssertFalse(state.allowsCustomModels(for: "missing"))
        XCTAssertNil(state.modelCatalogCount(for: "missing", model: "glm-5.2"))
        XCTAssertNil(state.modelCatalogCount(for: "openCodeGo", model: "   "))
        XCTAssertEqual(
            state.routePresentation(for: "missing", model: "glm-5.2").routeName,
            L10n.tr("Route unavailable")
        )
        XCTAssertEqual(
            state.routePresentation(for: "openCodeGo", model: "   ").routeName,
            L10n.tr("Route unavailable")
        )
        XCTAssertEqual(
            state.routePresentation(for: "openCodeGo", model: "minimax-m3").routeName,
            L10n.tr("Route unavailable")
        )
        XCTAssertEqual(
            state.routePresentation(for: "openCodeGo", model: "not-a-model").routeName,
            L10n.tr("Route unavailable")
        )
        XCTAssertTrue(
            state.routePresentation(for: "openCodeGo", model: "glm-5.2").bridgeEnabled
        )
        XCTAssertFalse(
            state.routePresentation(for: "openCodeGo", model: "gpt-5.6-luna").bridgeEnabled
        )
        XCTAssertTrue(
            state.routePresentation(
                for: "openCodeGo",
                model: "glm-5.2",
                preserveSessions: true
            ).bridgeEnabled
        )
        XCTAssertFalse(state.endpoint(for: "openCodeGo", model: "glm-5.2").isEmpty)
        XCTAssertEqual(state.providerName(for: "openCodeGo"), "OpenCode Go")
        XCTAssertTrue(state.isDefaultModel("glm-5.2", for: "openCodeGo"))
        XCTAssertFalse(state.isDefaultModel("deepseek-v4-flash", for: "openCodeGo"))
        XCTAssertGreaterThan(
            state.modelCatalogCount(
                for: "openCodeGo",
                model: "glm-5.2",
                catalogScope: .allSupported
            ) ?? 0,
            1
        )
        XCTAssertEqual(
            Set(state.modelOptions(for: "openCodeGo").map(\.transport)),
            [.responses, .chatCompletions]
        )
        XCTAssertFalse(state.modelOptions(for: "openCodeGo").contains { $0.id.contains("minimax") })
        XCTAssertTrue(state.allowsCustomModels(for: "openRouter"))
        for option in state.modelOptions(for: "openCodeGo") {
            XCTAssertFalse(option.transport.label.isEmpty)
        }

        await state.applySelectedProfile()
        XCTAssertNotNil(state.errorMessage)

        state.beginCreatingProfile()
        XCTAssertTrue(state.isCreatingProfile)
        XCTAssertTrue(state.isShowingNewProfile)
        state.editorDraft.name = "   "
        _ = await state.saveEditor()
        XCTAssertNotNil(state.errorMessage)

        state.editorDraft = AppState.ProfileDraft(
            name: "DeepSeek Flash",
            presetKey: "openCodeGo",
            model: "deepseek-v4-flash",
            preserveSessions: true,
            catalogScope: .allSupported,
            apiKey: "test-api-key"
        )
        XCTAssertEqual(state.editorCredentialStatus, .newValue)
        let saved = await state.saveEditor()
        let savedID = try XCTUnwrap(saved)
        XCTAssertEqual(state.selectedProfileID, savedID)
        XCTAssertEqual(state.editorCredentialStatus, .saved)
        XCTAssertEqual(state.selectedProfileItem?.name, "DeepSeek Flash")
        XCTAssertTrue(state.selectedProfileItem?.requiresLoopbackBridge ?? false)

        state.cancelCreatingProfile()
        state.beginRestore()
        XCTAssertTrue(state.isShowingRestore)
        await waitUntilIdle(state)
        state.cancelRestore()
        XCTAssertFalse(state.isShowingRestore)

        await state.previewEditor()
        XCTAssertNotNil(state.preview)
        XCTAssertTrue(state.preview?.bridgeEnabled ?? false)
        XCTAssertFalse(state.preview?.changes.isEmpty ?? true)

        await state.applySelectedProfile()
        XCTAssertTrue(state.restartRequired)
        XCTAssertTrue(state.modelCatalogStatus.isApplied)
        XCTAssertTrue(
            state.modelCatalogStatus.matches(
                profileID: savedID,
                model: "deepseek-v4-flash",
                catalogScope: .allSupported
            )
        )
        XCTAssertFalse(
            state.modelCatalogStatus.matches(
                profileID: savedID,
                model: "glm-5.2",
                catalogScope: .allSupported
            )
        )
        XCTAssertTrue(state.canUndoLastSwitch)
        XCTAssertTrue(state.hasPersistentUndo)
        XCTAssertEqual(state.statusMessage, AppState.restartRequiredMessage)

        host(
            ContentView()
                .environmentObject(state)
                .environmentObject(AppSettings(defaults: isolatedDefaults()))
        )
        host(
            MenuBarView()
                .environmentObject(state)
                .environmentObject(AppSettings(defaults: isolatedDefaults()))
        )
        host(
            ProfileEditorView(draft: Binding(
                get: { state.editorDraft },
                set: { state.editorDraft = $0 }
            ), isNew: false)
            .environmentObject(state)
        )
        host(RestartRequiredBanner().environmentObject(state))
        host(ModelCatalogStatusView(status: state.modelCatalogStatus))
        host(ModelCatalogStatusView(status: .pending, compact: true))
        host(ModelCatalogStatusView(status: .restored, compact: false))
        host(
            ModelCatalogStatusView(
                status: AppState.ModelCatalogStatus(
                    state: .applied,
                    modelCount: nil,
                    profileID: savedID,
                    model: "deepseek-v4-flash",
                    catalogScope: .selectedModel
                )
            )
        )
        host(BridgeStatusBadge(status: .running))
        host(BridgeStatusBadge(status: .stopped))
        host(SettingsView().environmentObject(AppSettings(defaults: isolatedDefaults())))

        state.isShowingRestore = true
        host(
            ContentView()
                .environmentObject(state)
                .environmentObject(AppSettings(defaults: isolatedDefaults()))
        )

        let backups = try adapter.listConfigurationBackups()
        XCTAssertFalse(backups.isEmpty)
        await state.restore(backups[0])
        XCTAssertEqual(state.modelCatalogStatus, .restored)

        await state.undoLastSwitch()
        state.dismissRestartRequired()
        XCTAssertFalse(state.restartRequired)

        await state.quickApply(profileID: savedID)
        XCTAssertTrue(state.restartRequired)
        state.dismissRestartRequired()

        state.selectedProfileID = UUID()
        state.prepareEditorForSelection()
        XCTAssertNil(state.preview)

        state.editorDraft = AppState.ProfileDraft(
            id: savedID,
            name: "Updated",
            presetKey: "openCodeGo",
            model: "gpt-5.6-luna",
            apiKey: ""
        )
        _ = await state.saveEditor()
        XCTAssertEqual(state.profileItems.first?.model, "gpt-5.6-luna")
    }

    func testAppStateReportsPreparationAndRestoreUnavailableFailures() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let throwingState = AppState(
            profileRepository: ProfileRepository(
                storageURL: directoryURL.appendingPathComponent("profiles.json")
            ),
            credentialStore: InMemoryAppCredentialStore(),
            clientAdapter: ThrowingClientAdapter(),
            receiptRepository: SwitchReceiptRepository(
                storageURL: directoryURL.appendingPathComponent("switch-receipts.json")
            )
        )
        await waitUntilLoaded(throwingState)
        XCTAssertNotNil(throwingState.errorMessage)

        await throwingState.restore(
            CodexConfigurationBackup(
                url: directoryURL.appendingPathComponent("missing.toml"),
                date: Date(),
                byteSize: 12
            )
        )
        XCTAssertNotNil(throwingState.errorMessage)

        throwingState.beginCreatingProfile()
        throwingState.editorDraft.presetKey = "not-a-preset"
        throwingState.editorDraft.name = "Broken"
        throwingState.editorDraft.model = "glm-5.2"
        _ = await throwingState.saveEditor()
        XCTAssertNotNil(throwingState.errorMessage)

        throwingState.editorDraft.presetKey = "openCodeGo"
        throwingState.editorDraft.model = ""
        await throwingState.previewEditor()
        XCTAssertNotNil(throwingState.errorMessage)

        await throwingState.undoLastSwitch()
        await throwingState.quickApply(profileID: UUID())
        await throwingState.refreshRestoreData()
    }

    func testAppLanguageViewModifierAndSettingsColorRoundTrip() {
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.appearance = .light
        settings.language = .korean
        host(
            Text("hello")
                .applyingAppLanguage(.korean)
                .environmentObject(settings)
        )
        settings.appearance = .system
        settings.appearance = .dark
        XCTAssertEqual(AppLanguage.french.localizedString(forKey: "English").isEmpty, false)
    }

    func testSwiftUIRowsPreviewRestoreAndFriendlyCoreErrors() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let credentials = InMemoryAppCredentialStore()
        let adapter = CodexClientAdapter(
            configURL: directoryURL
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("config.toml"),
            credentialStore: credentials,
            bridgeManager: CoverageBridgeManager()
        )
        let state = AppState(
            profileRepository: ProfileRepository(
                storageURL: directoryURL.appendingPathComponent("profiles.json")
            ),
            credentialStore: credentials,
            clientAdapter: adapter,
            receiptRepository: SwitchReceiptRepository(
                storageURL: directoryURL.appendingPathComponent("switch-receipts.json")
            )
        )
        await waitUntilLoaded(state)

        host(EmptyStateView(createProfile: {}))
        host(RestoreBackupView().environmentObject(state))

        let backup = CodexConfigurationBackup(
            url: directoryURL.appendingPathComponent("config-backup.toml"),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            byteSize: 2048
        )
        XCTAssertEqual(backup.id, backup.url)
        XCTAssertEqual(backup.createdAt, backup.date)
        XCTAssertEqual(backup.size, 2048)
        host(RestoreBackupRow(backup: backup))

        let receipt = SwitchReceipt(
            backupURL: backup.url,
            beforeHash: "aaa",
            afterHash: "bbb",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            originalConfigExisted: true
        )
        host(
            UndoJournalRow(
                entry: SwitchReceiptJournalEntry(
                    receipt: receipt,
                    profileName: "DeepSeek",
                    model: "deepseek-v4-flash",
                    providerDisplayName: "OpenCode Go"
                )
            )
        )
        host(
            UndoJournalRow(
                entry: SwitchReceiptJournalEntry(
                    receipt: receipt,
                    profileName: nil,
                    model: nil,
                    providerDisplayName: nil
                )
            )
        )

        let inactive = AppState.ProfileListItem(
            id: UUID(),
            name: "Idle",
            providerName: "OpenCode Go",
            model: "glm-5.2",
            isActive: false,
            requiresLoopbackBridge: false,
            bridgeStatus: nil
        )
        let active = AppState.ProfileListItem(
            id: UUID(),
            name: "Live",
            providerName: "OpenCode Go",
            model: "deepseek-v4-flash",
            isActive: true,
            requiresLoopbackBridge: true,
            bridgeStatus: .running
        )
        host(ProfileRow(item: inactive))
        host(ProfileRow(item: active))

        for option in state.modelOptions(for: "openCodeGo") {
            _ = option.isChatOnly
            _ = option.transport.label
        }

        let fullPreview = AppState.PreviewSnapshot(
            profileID: UUID(),
            profileName: "Preview",
            providerName: "OpenCode Go",
            endpoint: "http://127.0.0.1:14556/v1",
            routeName: "Chat Completions",
            bridgeEnabled: true,
            bridgeStatus: .running,
            loopbackEndpoint: "http://127.0.0.1:14556/v1",
            upstreamEndpoint: "https://opencode.ai/zen/go/v1/chat/completions",
            model: "deepseek-v4-flash",
            modelCatalogCount: 8,
            summary: "Ready",
            projectedConfig: "model = \"deepseek-v4-flash\"\n",
            changes: ["update config"],
            warnings: ["keep app open"]
        )
        let sparsePreview = AppState.PreviewSnapshot(
            profileID: UUID(),
            profileName: "Sparse",
            providerName: "OpenRouter",
            endpoint: "https://openrouter.ai/api/v1",
            routeName: "Responses",
            bridgeEnabled: false,
            bridgeStatus: nil,
            loopbackEndpoint: nil,
            upstreamEndpoint: nil,
            model: "openai/gpt-5.3-codex",
            modelCatalogCount: nil,
            summary: "Direct",
            projectedConfig: "model = \"x\"\n",
            changes: [],
            warnings: []
        )
        host(PreviewSection(preview: fullPreview))
        host(PreviewSection(preview: sparsePreview))

        state.beginCreatingProfile()
        state.editorDraft.name = "Routed"
        state.editorDraft.presetKey = "openCodeGo"
        state.editorDraft.model = "deepseek-v4-flash"
        state.editorDraft.preserveSessions = true
        state.editorDraft.apiKey = "key"
        _ = await state.saveEditor()
        await state.previewEditor()
        host(
            ProfileEditorView(
                draft: Binding(
                    get: { state.editorDraft },
                    set: { state.editorDraft = $0 }
                ),
                isNew: false
            )
            .environmentObject(state)
        )
        host(RestoreBackupView().environmentObject(state))

        let errorState = AppState(
            profileRepository: ProfileRepository(
                storageURL: directoryURL.appendingPathComponent("errors.json")
            ),
            credentialStore: InMemoryAppCredentialStore(),
            clientAdapter: SelectiveThrowingAdapter(error: CodexSwitchError.invalidProfile),
            receiptRepository: SwitchReceiptRepository(
                storageURL: directoryURL.appendingPathComponent("error-receipts.json")
            )
        )
        await waitUntilLoaded(errorState)
        errorState.beginCreatingProfile()
        errorState.editorDraft.name = "Err"
        errorState.editorDraft.presetKey = "openCodeGo"
        errorState.editorDraft.model = "glm-5.2"
        _ = await errorState.saveEditor()

        let catalogErrors: [Error] = [
            CodexModelCatalogError.emptyModels,
            CodexModelCatalogError.tooManyModels,
            CodexModelCatalogError.duplicateModel,
            CodexModelCatalogError.invalidModelIdentifier,
            CodexModelCatalogError.invalidSchema,
            CodexModelCatalogError.catalogTooLarge,
            CodexModelCatalogError.unreadableCatalog,
            CodexModelCatalogError.unsafeCatalogPath
        ]
        let switchErrors: [Error] = [
            CodexSwitchError.invalidProfile,
            CodexSwitchError.malformedManagedMarkers,
            CodexSwitchError.misplacedActiveMarker,
            CodexSwitchError.missingCredential,
            CodexSwitchError.unreadableConfiguration,
            CodexSwitchError.unableToWriteConfiguration,
            CodexSwitchError.backupUnavailable,
            CodexSwitchError.backupIntegrityConflict,
            CodexSwitchError.configurationChanged,
            CodexSwitchError.modelCatalogChanged,
            CodexSwitchError.foreignModelCatalogPointer,
            CodexSwitchError.unsafeBackupPath,
            CodexSwitchError.invalidConfigurationBackup,
            CodexSwitchError.configurationBackupTooLarge,
            CodexSwitchError.foreignOpenAIBaseURL
        ]
        let journalErrors: [Error] = [
            SwitchReceiptRepositoryError.unableToWriteJournal,
            SwitchReceiptRepositoryError.unableToDeleteJournal
        ]
        for error in catalogErrors + switchErrors + journalErrors {
            let adapter = SelectiveThrowingAdapter(error: error)
            let isolated = AppState(
                profileRepository: ProfileRepository(
                    storageURL: directoryURL.appendingPathComponent("loop-\(UUID().uuidString).json")
                ),
                credentialStore: InMemoryAppCredentialStore(),
                clientAdapter: adapter,
                receiptRepository: SwitchReceiptRepository(
                    storageURL: directoryURL.appendingPathComponent("loop-r-\(UUID().uuidString).json")
                )
            )
            await waitUntilLoaded(isolated)
            isolated.beginCreatingProfile()
            isolated.editorDraft.name = "Loop"
            isolated.editorDraft.presetKey = "openCodeGo"
            isolated.editorDraft.model = "glm-5.2"
            _ = await isolated.saveEditor()
            await isolated.previewEditor()
            XCTAssertNotNil(isolated.errorMessage)
        }

        struct Unlocalized: Error {}
        let unlocalized = AppState(
            profileRepository: ProfileRepository(
                storageURL: directoryURL.appendingPathComponent("unlocalized.json")
            ),
            credentialStore: InMemoryAppCredentialStore(),
            clientAdapter: SelectiveThrowingAdapter(error: Unlocalized()),
            receiptRepository: SwitchReceiptRepository(
                storageURL: directoryURL.appendingPathComponent("unlocalized-r.json")
            )
        )
        await waitUntilLoaded(unlocalized)
        unlocalized.beginCreatingProfile()
        unlocalized.editorDraft.name = "Plain"
        unlocalized.editorDraft.presetKey = "openCodeGo"
        unlocalized.editorDraft.model = "glm-5.2"
        _ = await unlocalized.saveEditor()
        await unlocalized.previewEditor()
        XCTAssertNotNil(unlocalized.errorMessage)
    }
}

@MainActor
private func waitUntilLoaded(_ state: AppState) async {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if state.statusMessage != nil || state.errorMessage != nil {
            await waitUntilIdle(state)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    await state.loadProfiles()
    await waitUntilIdle(state)
}

@MainActor
private func waitUntilIdle(_ state: AppState) async {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, state.isBusy {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
private func host<V: View>(_ view: V) {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}

private func isolatedDefaults() -> UserDefaults {
    let suite = "AllInOneCodexTests.AppCoverage.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func makeTemporaryDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AllInOneCodexAppCoverage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

private final class InMemoryAppCredentialStore: CredentialStoring {
    private var credentials: [UUID: Data] = [:]

    func save(_ credential: Data, for profileID: UUID) throws {
        credentials[profileID] = credential
    }

    func read(for profileID: UUID) throws -> Data {
        guard let credential = credentials[profileID] else {
            throw CredentialStoreError.notFound
        }
        return credential
    }

    func delete(for profileID: UUID) throws {
        credentials.removeValue(forKey: profileID)
    }
}

private final class CoverageBridgeManager: OpenCodeGoBridgeManaging, OpenCodeGoBridgeConfiguring {
    var statusValue: OpenCodeGoBridgeStatus = .stopped
    var status: OpenCodeGoBridgeStatus { statusValue }

    func configureLegacyChatMode() {}

    func configurePreservingSessions(route: ProviderRoute, credential: Data) {}

    func ensureRunning() throws {}

    func stop() {}
}

private struct SelectiveThrowingAdapter: ClientAdapter {
    let error: Error
    var bridgeStatus: OpenCodeGoBridgeStatus { .stopped }

    func prepareForUse() throws {}

    func preview(profile: ProviderProfile) throws -> SwitchPreview {
        throw error
    }

    func apply(profile: ProviderProfile) throws -> SwitchReceipt {
        throw error
    }

    func undo(_ receipt: SwitchReceipt) throws {
        throw error
    }
}

private struct ThrowingClientAdapter: ClientAdapter {
    var bridgeStatus: OpenCodeGoBridgeStatus { .stopped }

    func prepareForUse() throws {
        throw CodexSwitchError.unableToWriteConfiguration
    }

    func preview(profile: ProviderProfile) throws -> SwitchPreview {
        throw CodexSwitchError.invalidProfile
    }

    func apply(profile: ProviderProfile) throws -> SwitchReceipt {
        throw CodexSwitchError.missingCredential
    }

    func undo(_ receipt: SwitchReceipt) throws {
        throw CodexSwitchError.configurationChanged
    }
}
