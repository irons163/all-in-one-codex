import Darwin
import Foundation
import XCTest

@testable import AllInOneCodex

final class CodexCoreTests: XCTestCase {
    func testProviderCatalogContainsRequiredPresets() throws {
        let openCodeGo = try XCTUnwrap(ProviderCatalog.preset(for: .openCodeGo))
        XCTAssertEqual(openCodeGo.baseURL, "https://opencode.ai/zen/go/v1")
        XCTAssertEqual(openCodeGo.defaultModel, "glm-5.2")
        XCTAssertEqual(openCodeGo.providerID, "all_in_one_opencode_go_bridge")

        let openRouter = try XCTUnwrap(ProviderCatalog.preset(for: .openRouter))
        XCTAssertEqual(openRouter.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(openRouter.defaultModel, "openai/gpt-5.3-codex")
        XCTAssertEqual(openRouter.providerID, "all_in_one_openrouter")
    }

    func testProviderProfileLegacyJSONDefaultsPreserveSessionsToFalseAndRoundTripsTrue() throws {
        let profileID = UUID(uuidString: "5F15F99C-8CFB-4778-9B4C-DFB3A5AF7C51")!
        let legacyJSON = """
        {
          "id": "\(profileID.uuidString)",
          "name": "Legacy profile",
          "presetID": "openCodeGo",
          "model": "glm-5.2",
          "createdAt": 1700000000,
          "updatedAt": 1700000100
        }
        """

        let legacy = try JSONDecoder().decode(
            ProviderProfile.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertFalse(legacy.preserveSessions)

        let preserving = ProviderProfile(
            id: profileID,
            name: "Preserving profile",
            presetID: .openCodeGo,
            model: "glm-5.2",
            preserveSessions: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let roundTripped = try JSONDecoder().decode(
            ProviderProfile.self,
            from: JSONEncoder().encode(preserving)
        )
        XCTAssertEqual(roundTripped, preserving)
        XCTAssertTrue(roundTripped.preserveSessions)
    }

    func testCodexModelCatalogUsesCCSwitchCompatibleSchemaAndOpenCodeGoModels() throws {
        let catalog = try CodexModelCatalog.make(
            for: makeProfile(presetID: .openCodeGo)
        )
        let data = try catalog.encodedData()
        let decoded = try CodexModelCatalog.decodeValidated(from: data)
        let modelIDs = Set(catalog.models.map(\.slug))
        let expectedIDs = Set(
            ProviderCatalog.openCodeGoModels
                .filter {
                    $0.wireAPI == .responses || $0.wireAPI == .chatCompletions
                }
                .map(\.modelID)
        )

        XCTAssertEqual(decoded, catalog)
        XCTAssertEqual(modelIDs, expectedIDs)
        XCTAssertEqual(catalog.models.count, 12)
        XCTAssertTrue(modelIDs.contains("gpt-5.6-luna"))
        XCTAssertTrue(modelIDs.contains("deepseek-v4-flash"))
        XCTAssertTrue(modelIDs.contains("deepseek-v4-pro"))

        let flash = try XCTUnwrap(catalog.models.first { $0.slug == "deepseek-v4-flash" })
        XCTAssertEqual(flash.displayName, "deepseek-v4-flash")
        XCTAssertEqual(flash.description, "deepseek-v4-flash")
        XCTAssertEqual(flash.shellType, "shell_command")
        XCTAssertTrue(flash.supportsReasoningSummaries)
        XCTAssertFalse(flash.baseInstructions.isEmpty)

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(document["models"] as? [[String: Any]])
    }

    func testCodexModelCatalogIncludesCurrentOpenRouterCustomModelOnly() throws {
        let profile = makeProfile(
            presetID: .openRouter,
            model: "vendor/custom-model"
        )
        let catalog = try CodexModelCatalog.make(for: profile)

        XCTAssertEqual(catalog.models.map(\.slug), ["vendor/custom-model"])
        XCTAssertEqual(catalog.models.first?.displayName, "vendor/custom-model")
    }

    func testProjectsBothPresetsWithCommandBackedAuthentication() throws {
        let projector = CodexConfigProjector()

        for preset in ProviderCatalog.all {
            let profile = makeProfile(presetID: preset.id)
            let projection = try projector.project(original: "# User configuration\n", profile: profile)

            XCTAssertTrue(projection.contains("model = \"\(profile.model)\""))
            XCTAssertTrue(projection.contains("model_provider = \"\(preset.providerID)\""))
            XCTAssertTrue(projection.contains("base_url = \"\(preset.baseURL)\""))
            XCTAssertTrue(projection.contains("wire_api = \"responses\""))
            XCTAssertTrue(
                projection.contains(
                    "args = [\"find-generic-password\", \"-s\", \"\(KeychainCredentialStore.service)\", \"-a\", \"\(profile.id.uuidString)\", \"-w\"]"
                )
            )
            XCTAssertTrue(projection.contains("timeout_ms = 5000"))
            XCTAssertTrue(projection.contains("refresh_interval_ms = 0"))

            for managedPreset in ProviderCatalog.all {
                XCTAssertTrue(
                    projection.contains("[model_providers.\(managedPreset.providerID)]"),
                    "Both app-owned provider tables must be projected."
                )
            }
            XCTAssertFalse(projection.contains("env_key"))
            XCTAssertFalse(projection.contains("requires_openai_auth"))
            XCTAssertFalse(projection.contains("experimental_bearer_token"))
        }
    }

    func testProjectionPreservesUnknownSettingsCommentsAndMCP() throws {
        let original = """
        # Keep this user comment.
        approval_policy = "never"
        model = "legacy-model"
        model_provider = "legacy-provider"

        [mcp_servers.filesystem] # preserve this table comment
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]

        [unknown_feature]
        enabled = true
        """
        let projection = try CodexConfigProjector().project(
            original: original,
            profile: makeProfile(presetID: .openRouter)
        )

        XCTAssertTrue(projection.contains("# Keep this user comment."))
        XCTAssertTrue(projection.contains("approval_policy = \"never\""))
        XCTAssertTrue(projection.contains("[mcp_servers.filesystem]"))
        XCTAssertTrue(projection.contains("# preserve this table comment"))
        XCTAssertTrue(projection.contains("@modelcontextprotocol/server-filesystem"))
        XCTAssertTrue(projection.contains("[unknown_feature]"))
        XCTAssertFalse(projection.contains("model = \"legacy-model\""))
        XCTAssertFalse(projection.contains("model_provider = \"legacy-provider\""))

        let activeMarker = try XCTUnwrap(projection.range(of: CodexConfigProjector.activeBeginMarker))
        let firstTable = try XCTUnwrap(projection.range(of: "[mcp_servers.filesystem]"))
        XCTAssertLessThan(activeMarker.lowerBound, firstTable.lowerBound)
    }

    func testProjectionDisablesRequestCompressionInsideExistingFeaturesTable() throws {
        let original = """
        approval_policy = "never"

        [features]
        multi_agent = true
        enable_request_compression = true # incompatible with the Chat bridge

        [mcp_servers.example]
        command = "example"
        """
        let projector = CodexConfigProjector()
        let profile = makeProfile(
            presetID: .openCodeGo,
            model: "deepseek-v4-flash"
        )

        let projected = try projector.project(original: original, profile: profile)
        let projectedAgain = try projector.project(original: projected, profile: profile)

        for output in [projected, projectedAgain] {
            XCTAssertTrue(output.contains("[features]"))
            XCTAssertTrue(output.contains("multi_agent = true"))
            XCTAssertTrue(output.contains(CodexConfigProjector.compatibilityBeginMarker))
            XCTAssertTrue(output.contains("enable_request_compression = false"))
            XCTAssertFalse(output.contains("enable_request_compression = true"))
            XCTAssertTrue(output.contains("[mcp_servers.example]"))
            XCTAssertEqual(
                output.components(separatedBy: "enable_request_compression =").count - 1,
                1
            )
            XCTAssertEqual(
                output.components(separatedBy: CodexConfigProjector.compatibilityBeginMarker).count - 1,
                1
            )
        }
    }

    func testProjectionCreatesCompatibilityFeaturesTableWhenMissing() throws {
        let projection = try CodexConfigProjector().project(
            original: "approval_policy = \"never\"\n",
            profile: makeProfile(presetID: .openRouter, model: "vendor/model")
        )

        XCTAssertTrue(projection.contains("[features]"))
        XCTAssertTrue(projection.contains(CodexConfigProjector.compatibilityBeginMarker))
        XCTAssertTrue(projection.contains("enable_request_compression = false"))
        XCTAssertTrue(projection.contains(CodexConfigProjector.compatibilityEndMarker))
    }

    func testProjectionRetainsMultilineUnknownTopLevelValues() throws {
        let original = #"""
        notes = """
        model = "this belongs to the note"
        [mcp_servers.not_a_table]
        """
        model = "legacy-model"
        model_provider = "legacy-provider"

        [mcp_servers.real]
        command = "real-mcp"
        """#

        let projection = try CodexConfigProjector().project(
            original: original,
            profile: makeProfile(presetID: .openCodeGo)
        )

        XCTAssertTrue(projection.contains("model = \"this belongs to the note\""))
        XCTAssertTrue(projection.contains("[mcp_servers.not_a_table]"))
        XCTAssertTrue(projection.contains("[mcp_servers.real]"))
        XCTAssertFalse(projection.contains("model = \"legacy-model\""))
        XCTAssertFalse(projection.contains("model_provider = \"legacy-provider\""))
    }

    func testProjectionClaimsOnlyTheAppOwnedModelCatalogPointer() throws {
        let projector = CodexConfigProjector()
        let profile = makeProfile(presetID: .openCodeGo)
        let projected = try projector.project(original: "# User configuration\n", profile: profile)
        let projectedAgain = try projector.project(original: projected, profile: profile)

        XCTAssertTrue(projected.contains(CodexConfigProjector.catalogPointerMarker))
        XCTAssertTrue(
            projected.contains(
                "model_catalog_json = \"\(CodexModelCatalog.filename)\""
            )
        )
        XCTAssertEqual(
            projectedAgain.components(separatedBy: "model_catalog_json =").count - 1,
            1
        )

        let foreignPointer = """
        model_catalog_json = "my-custom-models.json"
        [mcp_servers.example]
        command = "example"
        """
        XCTAssertThrowsError(
            try projector.project(original: foreignPointer, profile: profile)
        ) { error in
            XCTAssertEqual(error as? CodexSwitchError, .foreignModelCatalogPointer)
        }
    }

    func testMalformedManagedMarkerIsConflict() {
        let original = """
        # BEGIN ALL-IN-ONE-CODEX ACTIVE
        model = "incomplete"
        """

        XCTAssertThrowsError(
            try CodexConfigProjector().project(
                original: original,
                profile: makeProfile(presetID: .openCodeGo)
            )
        ) { error in
            XCTAssertEqual(error as? CodexSwitchError, .malformedManagedMarkers)
        }
    }

    func testProjectionAndApplyNeverIncludeCredentialMaterial() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = directoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        let profile = makeProfile(presetID: .openCodeGo)
        let credentials = FakeCredentialStore()
        let keyMaterial = UUID().uuidString + UUID().uuidString
        try credentials.save(Data(keyMaterial.utf8), for: profile.id)

        let adapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            bridgeManager: FakeBridgeManager()
        )
        let preview = try adapter.preview(profile: profile)
        XCTAssertFalse(preview.projected.contains(keyMaterial))

        let receipt = try adapter.apply(profile: profile)
        let appliedConfiguration = try String(contentsOf: configURL, encoding: .utf8)
        let catalogURL = try XCTUnwrap(receipt.catalogURL)
        let appliedCatalog = try String(contentsOf: catalogURL, encoding: .utf8)
        XCTAssertFalse(appliedConfiguration.contains(keyMaterial))
        XCTAssertFalse(appliedCatalog.contains(keyMaterial))
        XCTAssertFalse(appliedCatalog.contains("http://"))
        XCTAssertFalse(appliedCatalog.contains("https://"))
    }

    func testApplyBacksUpAtomicallyUndoesAndDetectsHashConflict() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configDirectory = directoryURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("config.toml")
        let original = """
        # Existing setting
        approval_policy = "on-request"

        [mcp_servers.example]
        command = "example-mcp"
        """
        try Data(original.utf8).write(to: configURL)

        let profile = makeProfile(presetID: .openRouter)
        let credentials = FakeCredentialStore()
        try credentials.save(Data(repeating: 0xA5, count: 32), for: profile.id)
        let adapter = CodexClientAdapter(configURL: configURL, credentialStore: credentials)

        let receipt = try adapter.apply(profile: profile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.backupURL.path))
        let catalogURL = try XCTUnwrap(receipt.catalogURL)
        let catalogBackupURL = try XCTUnwrap(receipt.catalogBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogBackupURL.path))
        XCTAssertNotEqual(try String(contentsOf: configURL, encoding: .utf8), original)

        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o777, 0o600)
        let catalogAttributes = try FileManager.default.attributesOfItem(atPath: catalogURL.path)
        let catalogPermissions = try XCTUnwrap(
            (catalogAttributes[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(catalogPermissions & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: configDirectory.path
        )
        let directoryPermissions = try XCTUnwrap(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(directoryPermissions & 0o777, 0o700)

        try adapter.undo(receipt)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))

        let secondReceipt = try adapter.apply(profile: profile)
        try Data("# External edit\n".utf8).write(to: configURL)
        XCTAssertThrowsError(try adapter.undo(secondReceipt)) { error in
            XCTAssertEqual(error as? CodexSwitchError, .configurationChanged)
        }
    }

    func testApplyAndUndoRestoreBothConfigurationAndExistingCatalog() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configDirectory = directoryURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("config.toml")
        let catalogURL = configDirectory.appendingPathComponent(CodexModelCatalog.filename)
        let originalConfiguration = "approval_policy = \"on-request\"\n"
        let originalCatalog = try CodexModelCatalog.make(
            for: makeProfile(presetID: .openRouter, model: "vendor/original-model")
        ).encodedData()
        try Data(originalConfiguration.utf8).write(to: configURL)
        try originalCatalog.write(to: catalogURL)

        let profile = makeProfile(presetID: .openRouter, model: "vendor/new-model")
        let credentials = FakeCredentialStore()
        try credentials.save(Data("test-credential".utf8), for: profile.id)
        let adapter = CodexClientAdapter(configURL: configURL, credentialStore: credentials)

        let receipt = try adapter.apply(profile: profile)
        XCTAssertNotEqual(try Data(contentsOf: configURL), Data(originalConfiguration.utf8))
        XCTAssertNotEqual(try Data(contentsOf: catalogURL), originalCatalog)

        try adapter.undo(receipt)
        XCTAssertEqual(try Data(contentsOf: configURL), Data(originalConfiguration.utf8))
        XCTAssertEqual(try Data(contentsOf: catalogURL), originalCatalog)
    }

    func testUndoRejectsCatalogHashConflictWithoutRestoringConfiguration() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configDirectory = directoryURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("config.toml")
        let originalConfiguration = "approval_policy = \"on-request\"\n"
        try Data(originalConfiguration.utf8).write(to: configURL)

        let profile = makeProfile(presetID: .openCodeGo)
        let credentials = FakeCredentialStore()
        try credentials.save(Data("test-credential".utf8), for: profile.id)
        let adapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            bridgeManager: FakeBridgeManager()
        )

        let receipt = try adapter.apply(profile: profile)
        let catalogURL = try XCTUnwrap(receipt.catalogURL)
        let changedCatalog = try CodexModelCatalog.make(
            for: makeProfile(presetID: .openRouter, model: "vendor/changed-model")
        ).encodedData()
        try changedCatalog.write(to: catalogURL)

        XCTAssertThrowsError(try adapter.undo(receipt)) { error in
            XCTAssertEqual(error as? CodexSwitchError, .modelCatalogChanged)
        }
        XCTAssertNotEqual(
            try Data(contentsOf: configURL),
            Data(originalConfiguration.utf8)
        )
    }

    func testLegacySwitchReceiptDecodesWithoutCatalogFields() throws {
        let legacyJSON = """
        {
          "backupURL": "file:///tmp/legacy-config-backup",
          "beforeHash": "before",
          "afterHash": "after",
          "timestamp": 0,
          "originalConfigExisted": true
        }
        """

        let receipt = try JSONDecoder().decode(SwitchReceipt.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(receipt.catalogURL)
        XCTAssertNil(receipt.catalogBackupURL)
        XCTAssertNil(receipt.catalogBeforeHash)
        XCTAssertNil(receipt.catalogAfterHash)
        XCTAssertFalse(receipt.originalCatalogExisted)
        XCTAssertTrue(receipt.catalogAfterExisted)
    }

    func testSwitchReceiptRepositoryRoundTripsRetainsNewestAndStoresNoSecrets() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let storageURL = directoryURL
            .appendingPathComponent("AllInOneCodex", isDirectory: true)
            .appendingPathComponent("switch-receipts.json")
        let repository = SwitchReceiptRepository(storageURL: storageURL)
        let profile = makeProfile(
            presetID: .openRouter,
            model: "vendor/journal-model"
        )
        let credentialMaterial = "credential-\(UUID().uuidString)"
        let configurationContents = "approval_policy = \"never\"\n\(UUID().uuidString)"

        for index in 0...20 {
            let receipt = SwitchReceipt(
                backupURL: directoryURL
                    .appendingPathComponent("backups", isDirectory: true)
                    .appendingPathComponent("config.toml.backup-\(index)"),
                beforeHash: "before-\(index)",
                afterHash: "after-\(index)",
                timestamp: Date(timeIntervalSince1970: Double(index)),
                originalConfigExisted: true
            )
            _ = try await repository.save(receipt: receipt, profile: profile)
        }

        let entries = await repository.load()
        XCTAssertEqual(entries.count, SwitchReceiptRepository.maximumEntries)
        XCTAssertEqual(entries.first?.receipt.afterHash, "after-20")
        XCTAssertFalse(entries.contains { $0.receipt.beforeHash == "before-0" })
        XCTAssertEqual(entries.first?.profileName, profile.name)
        XCTAssertEqual(entries.first?.model, profile.model)

        let serialized = try String(contentsOf: storageURL, encoding: .utf8)
        XCTAssertFalse(serialized.contains(credentialMaterial))
        XCTAssertFalse(serialized.contains(configurationContents))

        let reloadedRepository = SwitchReceiptRepository(storageURL: storageURL)
        let reloaded = await reloadedRepository.load()
        XCTAssertEqual(reloaded, entries)
        let newestID = try XCTUnwrap(entries.first?.id)
        try await repository.delete(id: newestID)
        let remainingEntries = await repository.load()
        XCTAssertEqual(remainingEntries.count, 19)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        let filePermissions = try XCTUnwrap(
            (fileAttributes[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(filePermissions & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: storageURL.deletingLastPathComponent().path
        )
        let directoryPermissions = try XCTUnwrap(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(directoryPermissions & 0o777, 0o700)
    }

    func testSwitchReceiptRepositoryTreatsCorruptJournalAsEmpty() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let storageURL = directoryURL
            .appendingPathComponent("AllInOneCodex", isDirectory: true)
            .appendingPathComponent("switch-receipts.json")
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not valid json".utf8).write(to: storageURL)

        let repository = SwitchReceiptRepository(storageURL: storageURL)
        let entries = await repository.load()
        XCTAssertTrue(entries.isEmpty)
    }

    func testConfigurationBackupInventoryOrdersOnlyValidConfigurationBackupsAndRejectsTraversal() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = try makeCodexConfigurationURL(in: directoryURL)
        let backupsURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)

        let olderBackupURL = backupsURL.appendingPathComponent(
            "config.toml.backup-20260101T010203.004Z"
        )
        let newerBackupURL = backupsURL.appendingPathComponent(
            "config.toml.backup-20260201T010203.004Z"
        )
        try Data("approval_policy = \"on-request\"\n".utf8).write(to: olderBackupURL)
        try Data("approval_policy = \"never\"\n".utf8).write(to: newerBackupURL)
        try Data("not a configuration backup".utf8).write(
            to: backupsURL.appendingPathComponent(
                "all-in-one-codex-model-catalog.json.backup-20260201T010203.004Z"
            )
        )
        try Data("ignored".utf8).write(
            to: backupsURL.appendingPathComponent("unrelated.backup-20260201T010203.004Z")
        )

        let adapter = CodexClientAdapter(configURL: configURL, credentialStore: FakeCredentialStore())
        let backups = try adapter.listConfigurationBackups()
        XCTAssertEqual(backups.map(\.url), [
            newerBackupURL.standardizedFileURL,
            olderBackupURL.standardizedFileURL
        ])
        XCTAssertEqual(backups.map(\.kind), [.configuration, .configuration])
        XCTAssertEqual(backups.first?.byteSize, Int64(Data("approval_policy = \"never\"\n".utf8).count))

        let outsideDirectoryURL = directoryURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("approval_policy = \"never\"\n".utf8).write(
            to: outsideDirectoryURL.appendingPathComponent(
                "config.toml.backup-20260304T050607.008Z"
            )
        )
        let traversalURL = backupsURL.appendingPathComponent(
            "../outside/config.toml.backup-20260304T050607.008Z"
        )
        XCTAssertThrowsError(
            try adapter.restoreConfigurationBackup(at: traversalURL)
        ) { error in
            XCTAssertEqual(error as? CodexSwitchError, .unsafeBackupPath)
        }
    }

    func testManualRestoreRestoresMatchingCatalogAndSafetyReceiptUndoesIt() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = try makeCodexConfigurationURL(in: directoryURL)
        let configDirectoryURL = configURL.deletingLastPathComponent()
        let catalogURL = configDirectoryURL.appendingPathComponent(CodexModelCatalog.filename)
        let projector = CodexConfigProjector()
        let currentProfile = makeProfile(
            presetID: .openRouter,
            model: "vendor/current-model"
        )
        let restoredProfile = makeProfile(
            presetID: .openRouter,
            model: "vendor/restored-model"
        )
        let currentConfiguration = try projector.project(
            original: "# Current configuration\n",
            profile: currentProfile
        )
        let currentCatalog = try CodexModelCatalog.make(for: currentProfile).encodedData()
        try Data(currentConfiguration.utf8).write(to: configURL)
        try currentCatalog.write(to: catalogURL)

        let backupsURL = configDirectoryURL.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let suffix = "20260304T050607.008Z"
        let selectedBackupURL = backupsURL.appendingPathComponent(
            "config.toml.backup-\(suffix)"
        )
        let restoredConfiguration = try projector.project(
            original: "# Restored configuration\n",
            profile: restoredProfile
        )
        let restoredCatalog = try CodexModelCatalog.make(for: restoredProfile).encodedData()
        try Data(restoredConfiguration.utf8).write(to: selectedBackupURL)
        try restoredCatalog.write(
            to: backupsURL.appendingPathComponent(
                "\(CodexModelCatalog.filename).backup-\(suffix)"
            )
        )

        let adapter = CodexClientAdapter(configURL: configURL, credentialStore: FakeCredentialStore())
        let receipt = try adapter.restoreConfigurationBackup(at: selectedBackupURL)
        XCTAssertEqual(try Data(contentsOf: configURL), Data(restoredConfiguration.utf8))
        XCTAssertEqual(try Data(contentsOf: catalogURL), restoredCatalog)
        XCTAssertTrue(receipt.catalogAfterExisted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.backupURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(receipt.catalogBackupURL).path))

        try adapter.undo(receipt)
        XCTAssertEqual(try Data(contentsOf: configURL), Data(currentConfiguration.utf8))
        XCTAssertEqual(try Data(contentsOf: catalogURL), currentCatalog)

        let conflictReceipt = try adapter.restoreConfigurationBackup(at: selectedBackupURL)
        try Data("# External edit\n".utf8).write(to: configURL)
        XCTAssertThrowsError(try adapter.undo(conflictReceipt)) { error in
            XCTAssertEqual(error as? CodexSwitchError, .configurationChanged)
        }
    }

    func testManualRestoreRejectsMissingCatalogPairWithoutPartialChange() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = try makeCodexConfigurationURL(in: directoryURL)
        let configDirectoryURL = configURL.deletingLastPathComponent()
        let catalogURL = configDirectoryURL.appendingPathComponent(CodexModelCatalog.filename)
        let currentConfiguration = "approval_policy = \"on-request\"\n"
        let currentCatalog = try CodexModelCatalog.make(
            for: makeProfile(presetID: .openRouter, model: "vendor/current-model")
        ).encodedData()
        try Data(currentConfiguration.utf8).write(to: configURL)
        try currentCatalog.write(to: catalogURL)

        let restoreProfile = makeProfile(
            presetID: .openRouter,
            model: "vendor/restored-model"
        )
        let selectedConfiguration = try CodexConfigProjector().project(
            original: "# Needs a catalog pair\n",
            profile: restoreProfile
        )
        let backupsURL = configDirectoryURL.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let selectedBackupURL = backupsURL.appendingPathComponent(
            "config.toml.backup-20260304T050607.009Z"
        )
        try Data(selectedConfiguration.utf8).write(to: selectedBackupURL)

        let adapter = CodexClientAdapter(configURL: configURL, credentialStore: FakeCredentialStore())
        XCTAssertThrowsError(
            try adapter.restoreConfigurationBackup(at: selectedBackupURL)
        ) { error in
            XCTAssertEqual(error as? CodexSwitchError, .backupUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: configURL), Data(currentConfiguration.utf8))
        XCTAssertEqual(try Data(contentsOf: catalogURL), currentCatalog)
    }

    func testManualRestoreRollsBackCatalogWhenConfigurationWriteFails() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = try makeCodexConfigurationURL(in: directoryURL)
        let configDirectoryURL = configURL.deletingLastPathComponent()
        let catalogURL = configDirectoryURL.appendingPathComponent(CodexModelCatalog.filename)
        let currentConfiguration = "approval_policy = \"on-request\"\n"
        let currentCatalog = try CodexModelCatalog.make(
            for: makeProfile(presetID: .openRouter, model: "vendor/current-model")
        ).encodedData()
        try Data(currentConfiguration.utf8).write(to: configURL)
        try currentCatalog.write(to: catalogURL)

        let backupsURL = configDirectoryURL.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let selectedBackupURL = backupsURL.appendingPathComponent(
            "config.toml.backup-20260304T050607.011Z"
        )
        try Data("approval_policy = \"never\"\n".utf8).write(to: selectedBackupURL)

        let interceptor = OneShotConfigurationWriteFailure(configURL: configURL)
        let adapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: FakeCredentialStore(),
            projector: CodexConfigProjector(),
            bridgeManager: FakeBridgeManager(),
            atomicWriteInterceptor: interceptor
        )
        XCTAssertThrowsError(
            try adapter.restoreConfigurationBackup(at: selectedBackupURL)
        ) { error in
            XCTAssertEqual(error as? CodexSwitchError, .unableToWriteConfiguration)
        }
        XCTAssertEqual(try Data(contentsOf: configURL), Data(currentConfiguration.utf8))
        XCTAssertEqual(try Data(contentsOf: catalogURL), currentCatalog)
    }

    func testManualRestoreLeavesExternalCatalogUntouchedAndUndoRestoresOwnedCatalog() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = try makeCodexConfigurationURL(in: directoryURL)
        let configDirectoryURL = configURL.deletingLastPathComponent()
        let catalogURL = configDirectoryURL.appendingPathComponent(CodexModelCatalog.filename)
        let externalCatalogURL = configDirectoryURL.appendingPathComponent("external-models.json")
        let currentConfiguration = "approval_policy = \"on-request\"\n"
        let currentCatalog = try CodexModelCatalog.make(
            for: makeProfile(presetID: .openRouter, model: "vendor/current-model")
        ).encodedData()
        let externalCatalog = Data("{\"models\":[\"external\"]}".utf8)
        try Data(currentConfiguration.utf8).write(to: configURL)
        try currentCatalog.write(to: catalogURL)
        try externalCatalog.write(to: externalCatalogURL)

        let backupsURL = configDirectoryURL.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let selectedBackupURL = backupsURL.appendingPathComponent(
            "config.toml.backup-20260304T050607.010Z"
        )
        let externalPointerConfiguration = """
        approval_policy = "never"
        model_catalog_json = "external-models.json"
        """
        try Data(externalPointerConfiguration.utf8).write(to: selectedBackupURL)

        let adapter = CodexClientAdapter(configURL: configURL, credentialStore: FakeCredentialStore())
        let receipt = try adapter.restoreConfigurationBackup(at: selectedBackupURL)
        XCTAssertEqual(
            try String(contentsOf: configURL, encoding: .utf8),
            externalPointerConfiguration
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
        XCTAssertEqual(try Data(contentsOf: externalCatalogURL), externalCatalog)
        XCTAssertFalse(receipt.catalogAfterExisted)

        try adapter.undo(receipt)
        XCTAssertEqual(try Data(contentsOf: configURL), Data(currentConfiguration.utf8))
        XCTAssertEqual(try Data(contentsOf: catalogURL), currentCatalog)
        XCTAssertEqual(try Data(contentsOf: externalCatalogURL), externalCatalog)
    }

    func testProfileRepositoryRoundTripsMetadataWithoutCredentials() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let profile = makeProfile(presetID: .openRouter)
        let repository = ProfileRepository(
            storageURL: directoryURL
                .appendingPathComponent("AllInOneCodex", isDirectory: true)
                .appendingPathComponent("profiles.json")
        )

        try await repository.save([profile])
        let loadedProfiles = try await repository.load()
        XCTAssertEqual(loadedProfiles, [profile])
    }

    func testOpenCodeGoCapabilityCatalogContainsOfficialWireAPIs() {
        let responses = ProviderCatalog.openCodeGoModels
            .filter { $0.wireAPI == .responses }
            .map(\.modelID)
        let chat = Set(
            ProviderCatalog.openCodeGoModels
                .filter { $0.wireAPI == .chatCompletions }
                .map(\.modelID)
        )
        let messages = Set(
            ProviderCatalog.openCodeGoModels
                .filter { $0.wireAPI == .anthropicMessages }
                .map(\.modelID)
        )

        XCTAssertEqual(responses, ["gpt-5.6-luna"])
        XCTAssertEqual(
            chat,
            [
                "grok-4.5", "glm-5.2", "glm-5.1", "kimi-k3",
                "kimi-k2.7-code", "kimi-k2.6", "deepseek-v4-pro",
                "deepseek-v4-flash", "mimo-v2.5", "mimo-v2.5-pro", "hy3"
            ]
        )
        XCTAssertEqual(
            messages,
            [
                "minimax-m3", "minimax-m2.7", "qwen3.8-max",
                "qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus"
            ]
        )
    }

    func testRoutesDirectResponsesChatBridgeAndRejectsMessages() throws {
        let direct = try ProviderCatalog.route(
            for: makeProfile(presetID: .openCodeGo, model: "gpt-5.6-luna")
        )
        XCTAssertEqual(direct.providerID, "all_in_one_opencode_go")
        XCTAssertEqual(direct.baseURL, "https://opencode.ai/zen/go/v1")
        XCTAssertFalse(direct.requiresLoopbackBridge)

        let chat = try ProviderCatalog.route(
            for: makeProfile(presetID: .openCodeGo, model: "glm-5.2")
        )
        XCTAssertEqual(chat.providerID, "all_in_one_opencode_go_bridge")
        XCTAssertEqual(chat.baseURL, "http://127.0.0.1:14556/v1")
        XCTAssertEqual(chat.wireAPI, .responses)
        XCTAssertTrue(chat.requiresLoopbackBridge)

        let openRouter = try ProviderCatalog.route(
            for: makeProfile(presetID: .openRouter, model: "vendor/custom-model")
        )
        XCTAssertEqual(openRouter.providerID, "all_in_one_openrouter")
        XCTAssertEqual(openRouter.wireAPI, .responses)
        XCTAssertFalse(openRouter.requiresLoopbackBridge)

        XCTAssertThrowsError(
            try ProviderCatalog.route(
                for: makeProfile(presetID: .openCodeGo, model: "qwen3.8-max")
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderRoutingError,
                .unsupportedOpenCodeGoWireAPI(.anthropicMessages)
            )
        }
        XCTAssertThrowsError(
            try ProviderCatalog.route(
                for: makeProfile(presetID: .openCodeGo, model: "unlisted-model")
            )
        ) { error in
            XCTAssertEqual(error as? ProviderRoutingError, .unknownOpenCodeGoModel)
        }
    }

    func testChatProjectionUsesLoopbackWithoutFixtureCredential() throws {
        let fixtureSecret = "fixture-secret-must-not-appear"
        let profile = ProviderProfile(
            name: fixtureSecret,
            presetID: .openCodeGo,
            model: "glm-5.2",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let original = """
        # preserve this comment
        [mcp_servers.test]
        command = "test-mcp"
        """

        let projection = try CodexConfigProjector().project(
            original: original,
            profile: profile
        )

        XCTAssertTrue(
            projection.contains("model_provider = \"all_in_one_opencode_go_bridge\"")
        )
        XCTAssertTrue(
            projection.contains(
                "[model_providers.all_in_one_opencode_go_bridge]"
            )
        )
        XCTAssertTrue(
            projection.contains(
                "base_url = \"http://127.0.0.1:14556/v1\""
            )
        )
        XCTAssertTrue(projection.contains("# preserve this comment"))
        XCTAssertTrue(projection.contains("[mcp_servers.test]"))
        XCTAssertTrue(projection.contains("/usr/bin/security"))
        XCTAssertFalse(projection.contains(fixtureSecret))
    }

    func testConvertsInstructionsInputContentToolsAndTokenOptions() throws {
        let request = """
        {
          "model": "glm-5.2",
          "instructions": "Follow the system rule.",
          "input": [{
            "role": "user",
            "content": [
              {"type": "input_text", "text": "Describe this."},
              {"type": "input_image", "image_url": "https://example.invalid/image.png"},
              {"type": "input_file", "file_id": "file_123", "filename": "brief.pdf"},
              {"type": "input_audio", "input_audio": {"format": "wav", "data": "AA=="}}
            ]
          }],
          "tools": [{
            "type": "function",
            "name": "lookup_weather",
            "description": "Looks up weather.",
            "parameters": {"type": "object", "properties": {"city": {"type": "string"}}}
          }],
          "tool_choice": {"type": "function", "name": "lookup_weather"},
          "parallel_tool_calls": true,
          "max_output_tokens": 512,
          "stream": true,
          "stream_options": {"include_usage": false}
        }
        """

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Follow the system rule.")

        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, [
            "text", "image_url", "file", "input_audio"
        ])
        XCTAssertEqual(
            (content[1]["image_url"] as? [String: Any])?["url"] as? String,
            "https://example.invalid/image.png"
        )
        XCTAssertEqual(chat["max_tokens"] as? Int, 512)
        XCTAssertEqual(chat["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(
            (chat["stream_options"] as? [String: Any])?["include_usage"] as? Bool,
            true
        )
        let tools = try XCTUnwrap(chat["tools"] as? [[String: Any]])
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(
            ((tools[0]["function"] as? [String: Any])?["name"] as? String),
            "lookup_weather"
        )
        XCTAssertEqual(
            ((chat["tool_choice"] as? [String: Any])?["function"] as? [String: Any])?["name"] as? String,
            "lookup_weather"
        )
    }

    func testConvertsAssistantInputFunctionCalls() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "input": [[
                "role": "assistant",
                "content": [
                    ["type": "output_text", "text": "I will look that up."],
                    [
                        "type": "function_call",
                        "call_id": "call_lookup",
                        "name": "lookup_weather",
                        "arguments": "{\"city\":\"Taipei\"}"
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: data
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let message = try XCTUnwrap((chat["messages"] as? [[String: Any]])?.first)
        let toolCall = try XCTUnwrap((message["tool_calls"] as? [[String: Any]])?.first)

        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertEqual(
            ((message["content"] as? [[String: Any]])?.first?["text"] as? String),
            "I will look that up."
        )
        XCTAssertEqual(toolCall["id"] as? String, "call_lookup")
        XCTAssertEqual(
            ((toolCall["function"] as? [String: Any])?["arguments"] as? String),
            "{\"city\":\"Taipei\"}"
        )
    }

    func testConvertsTextSSEToResponsesTerminalSequence() throws {
        let upstream = """
        data: {"id":"chatcmpl_text","model":"glm-5.2","created":1700000000,"choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}

        data: {"id":"chatcmpl_text","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}

        data: [DONE]

        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.created"))
        XCTAssertTrue(events.contains("event: response.in_progress"))
        XCTAssertTrue(events.contains("event: response.output_text.delta"))
        XCTAssertTrue(events.contains("Hello world"))
        XCTAssertTrue(events.contains("event: response.output_item.done"))
        XCTAssertTrue(events.contains("event: response.completed"))
        XCTAssertTrue(events.contains("\"input_tokens\":4"))
        XCTAssertFalse(events.contains("[DONE]"))
    }

    func testConvertsReasoningSSEToResponsesReasoningEvents() throws {
        let upstream = """
        data: {"id":"chatcmpl_reasoning","model":"glm-5.2","choices":[{"index":0,"delta":{"reasoning_content":"I should check the units.","content":"The answer is 42."},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.reasoning_summary_text.delta"))
        XCTAssertTrue(events.contains("I should check the units."))
        XCTAssertTrue(events.contains("The answer is 42."))
        XCTAssertTrue(events.contains("event: response.completed"))
    }

    func testCoalescesFragmentedToolArgumentsFromSSE() throws {
        let upstream = #"""
        data: {"id":"chatcmpl_tool","model":"glm-5.2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_weather","type":"function","function":{"name":"lookup_weather","arguments":"{\"city\":\""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl_tool","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"Taipei\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """#
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2"
        )
        let toolCall = try XCTUnwrap(conversion.toolCalls.first)
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertEqual(toolCall.id, "call_weather")
        XCTAssertEqual(toolCall.name, "lookup_weather")
        XCTAssertEqual(toolCall.arguments, "{\"city\":\"Taipei\"}")
        XCTAssertTrue(events.contains("event: response.function_call_arguments.delta"))
        XCTAssertTrue(events.contains("event: response.function_call_arguments.done"))
    }

    func testMapsUsageAndLengthFinishReason() throws {
        let upstream = """
        {
          "id": "chatcmpl_length",
          "model": "glm-5.2",
          "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": "Partial answer"},
            "finish_reason": "length"
          }],
          "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}
        }
        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.completed"))
        XCTAssertFalse(events.contains("event: response.incomplete"))
        XCTAssertTrue(events.contains("\"status\":\"incomplete\""))
        XCTAssertTrue(events.contains("\"reason\":\"max_output_tokens\""))
        XCTAssertTrue(events.contains("\"input_tokens\":7"))
        XCTAssertTrue(events.contains("\"output_tokens\":3"))
        XCTAssertTrue(events.contains("\"total_tokens\":10"))
    }

    func testPreviousResponseToolOutputRebuildsAssistantToolCalls() throws {
        let cache = OpenCodeGoToolCallCache(capacity: 2)
        cache.store(
            responseID: "resp_prior",
            toolCalls: [
                OpenCodeGoToolCall(
                    id: "call_lookup",
                    name: "lookup_weather",
                    arguments: "{\"city\":\"Taipei\"}"
                )
            ],
            reasoningContent: "I should preserve this context."
        )
        let request: [String: Any] = [
            "model": "glm-5.2",
            "previous_response_id": "resp_prior",
            "input": [[
                "type": "function_call_output",
                "call_id": "call_lookup",
                "output": "Sunny"
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: data,
            toolCallCache: cache
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])

        XCTAssertEqual(messages[0]["role"] as? String, "assistant")
        XCTAssertEqual(
            (((messages[0]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String),
            "lookup_weather"
        )
        XCTAssertEqual(
            messages[0]["reasoning_content"] as? String,
            "I should preserve this context."
        )
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "call_lookup")
        XCTAssertEqual(messages[1]["content"] as? String, "Sunny")
    }

    func testKeepsToolHistoryBoundedWhileRetainingReasoning() {
        let cache = OpenCodeGoToolCallCache(capacity: 1)
        cache.store(
            responseID: "resp_first",
            toolCalls: [OpenCodeGoToolCall(id: "call_first", name: "first", arguments: "{}")],
            reasoningContent: "first reasoning"
        )
        cache.store(
            responseID: "resp_second",
            toolCalls: [OpenCodeGoToolCall(id: "call_second", name: "second", arguments: "{}")],
            reasoningContent: "second reasoning"
        )

        XCTAssertNil(cache.history(for: "resp_first"))
        XCTAssertEqual(
            cache.history(for: "resp_second")?.reasoningContent,
            "second reasoning"
        )
    }

    func testNormalizesErrorsWithoutLeakingUpstreamPayloads() {
        let encoding = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.unsupportedContentEncoding
        )
        XCTAssertEqual(encoding.statusCode, 415)
        XCTAssertEqual(encoding.code, "unsupported_content_encoding")

        let upstream = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 429
        )
        XCTAssertEqual(upstream.statusCode, 429)
        XCTAssertEqual(upstream.code, "upstream_rate_limited")

        let failure = OpenCodeGoChatResponseConverter.failureSSE(
            for: OpenCodeGoBridgeError.upstreamRejected,
            fallbackModel: "glm-5.2"
        )
        let events = String(data: failure, encoding: .utf8) ?? ""
        XCTAssertTrue(events.contains("event: response.failed"))
        XCTAssertFalse(events.contains("fixture-secret-must-not-leak"))
    }

    func testPreserveApplyConfiguresBridgeBeforeWritingAndKeepsCredentialOutOfFiles() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configURL = try makeCodexConfigurationURL(in: directoryURL)
        let catalogURL = configURL.deletingLastPathComponent()
            .appendingPathComponent(CodexModelCatalog.filename)
        let originalConfiguration = Data("approval_policy = \"never\"\n".utf8)
        let originalCatalog = try CodexModelCatalog.make(
            for: makeProfile(presetID: .openRouter, model: "vendor/original")
        ).encodedData()
        try originalConfiguration.write(to: configURL)
        try originalCatalog.write(to: catalogURL)

        let profileID = UUID(uuidString: "F566E13B-8CF5-40A2-AD33-0E718F71A4EF")!
        let profile = ProviderProfile(
            id: profileID,
            name: "Preserving profile",
            presetID: .openCodeGo,
            model: "glm-5.2",
            preserveSessions: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let selectedCredential = Data("selected-keychain-key".utf8)
        let credentials = FakeCredentialStore()
        try credentials.save(selectedCredential, for: profile.id)
        let bridge = ConfigurableFakeBridgeManager()
        bridge.onEnsure = {
            XCTAssertEqual(try Data(contentsOf: configURL), originalConfiguration)
            XCTAssertEqual(try Data(contentsOf: catalogURL), originalCatalog)
        }
        let adapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            bridgeManager: bridge
        )

        let receipt = try adapter.apply(profile: profile)
        XCTAssertEqual(bridge.events, ["configure-preserve", "ensure"])
        XCTAssertEqual(bridge.configuredCredential, selectedCredential)
        XCTAssertEqual(bridge.configuredRoute, try ProviderCatalog.route(for: profile))
        XCTAssertEqual(receipt.catalogURL?.standardizedFileURL, catalogURL.standardizedFileURL)

        let configuration = try String(contentsOf: configURL, encoding: .utf8)
        let catalog = try String(contentsOf: catalogURL, encoding: .utf8)
        XCTAssertTrue(configuration.contains(CodexConfigProjector.preserveSessionsMarker))
        XCTAssertTrue(configuration.contains("openai_base_url = \"\(ProviderCatalog.openCodeGoBridgeBaseURL)\""))
        XCTAssertFalse(configuration.contains("model_provider ="))
        XCTAssertFalse(configuration.contains(CodexConfigProjector.providersBeginMarker))
        XCTAssertFalse(configuration.contains("auth.command"))
        XCTAssertFalse(configuration.contains(String(data: selectedCredential, encoding: .utf8)!))
        XCTAssertFalse(catalog.contains(String(data: selectedCredential, encoding: .utf8)!))
    }

    func testPreserveApplyFailsClosedWhenBridgeCannotConfigure() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configURL = try makeCodexConfigurationURL(in: directoryURL)
        let catalogURL = configURL.deletingLastPathComponent()
            .appendingPathComponent(CodexModelCatalog.filename)
        let originalConfiguration = Data("approval_policy = \"on-request\"\n".utf8)
        let originalCatalog = try CodexModelCatalog.make(
            for: makeProfile(presetID: .openRouter, model: "vendor/original")
        ).encodedData()
        try originalConfiguration.write(to: configURL)
        try originalCatalog.write(to: catalogURL)

        let profile = makeProfile(
            presetID: .openCodeGo,
            model: "glm-5.2",
            preserveSessions: true
        )
        let credentials = FakeCredentialStore()
        try credentials.save(Data("selected-keychain-key".utf8), for: profile.id)
        let adapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            // This lightweight manager intentionally lacks the internal
            // configuration seam, so the adapter must fail before any write.
            bridgeManager: FakeBridgeManager()
        )

        XCTAssertThrowsError(try adapter.apply(profile: profile)) { error in
            XCTAssertEqual(error as? OpenCodeGoBridgeError, .unableToStart)
        }
        XCTAssertEqual(try Data(contentsOf: configURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: catalogURL), originalCatalog)
    }

    func testPrepareForUseRebuildsPreserveRouteAndReadsCredentialByMarkerProfileID() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configURL = try makeCodexConfigurationURL(in: directoryURL)
        let profileID = UUID(uuidString: "EE3ECF2B-67BB-43A4-9F6A-B3FD0F0E2375")!
        let profile = ProviderProfile(
            id: profileID,
            name: "Marker profile",
            presetID: .openCodeGo,
            model: "glm-5.2",
            preserveSessions: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let projected = try CodexConfigProjector().project(
            original: "approval_policy = \"never\"\n",
            profile: profile
        )
        try Data(projected.utf8).write(to: configURL)

        let selectedCredential = Data("marker-selected-key".utf8)
        let credentials = FakeCredentialStore()
        try credentials.save(selectedCredential, for: profile.id)
        try credentials.save(Data("other-profile-key".utf8), for: UUID())
        let bridge = ConfigurableFakeBridgeManager()
        let adapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            bridgeManager: bridge
        )

        try adapter.prepareForUse()
        XCTAssertEqual(bridge.events, ["configure-preserve", "ensure"])
        XCTAssertEqual(bridge.configuredCredential, selectedCredential)
        let route = try XCTUnwrap(bridge.configuredRoute)
        XCTAssertEqual(route.model, profile.model)
        XCTAssertEqual(route.providerID, ProviderCatalog.openCodeGoBridgeProviderID)
        XCTAssertEqual(route.baseURL, ProviderCatalog.openCodeGoBridgeBaseURL)
        XCTAssertEqual(route.upstreamBaseURL, ProviderCatalog.openCodeGoOfficialBaseURL)
        XCTAssertEqual(route.upstreamWireAPI, .chatCompletions)
    }

    func testChatApplyEnsuresBridgeBeforeConfigurationAndDirectApplyDoesNot() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configURL = directoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")

        let credentials = FakeCredentialStore()
        let chatProfile = makeProfile(presetID: .openCodeGo, model: "glm-5.2")
        try credentials.save(Data("test-credential".utf8), for: chatProfile.id)
        let chatBridge = FakeBridgeManager()
        chatBridge.onEnsure = {
            XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        }
        let chatAdapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            bridgeManager: chatBridge
        )

        _ = try chatAdapter.apply(profile: chatProfile)
        XCTAssertEqual(chatBridge.events, ["ensure"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))

        let directProfile = makeProfile(presetID: .openCodeGo, model: "gpt-5.6-luna")
        try credentials.save(Data("test-credential".utf8), for: directProfile.id)
        let directBridge = FakeBridgeManager()
        let directAdapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            bridgeManager: directBridge
        )

        _ = try directAdapter.apply(profile: directProfile)
        XCTAssertTrue(directBridge.events.isEmpty)
    }

    func testNormalizesDeveloperMessagesAndMissingFunctionSchemas() throws {
        let request = """
        {
          "model": "glm-5.2",
          "stream": true,
          "input": [
            {"role": "developer", "content": "Developer policy."},
            {"role": "system", "content": "System policy."},
            {
              "role": "user",
              "content": [
                {"type": "input_image", "image_url": "https://example.invalid/diagram.png"}
              ]
            }
          ],
          "tools": [
            {"type": "function", "name": "missing_parameters"},
            {
              "type": "function",
              "function": {"name": "null_parameters", "parameters": null}
            }
          ]
        }
        """

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "system")
        let imagePart = try XCTUnwrap(
            (messages[2]["content"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(
            (imagePart["image_url"] as? [String: Any])?["url"] as? String,
            "https://example.invalid/diagram.png"
        )

        let tools = try XCTUnwrap(chat["tools"] as? [[String: Any]])
        for tool in tools {
            let parameters = try XCTUnwrap(
                (tool["function"] as? [String: Any])?["parameters"] as? [String: Any]
            )
            XCTAssertEqual(parameters["type"] as? String, "object")
            XCTAssertNotNil(parameters["properties"] as? [String: Any])
        }
    }

    func testOmitsToolControlsWhenToolsAreEmpty() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "tools": [],
            "tool_choice": "required",
            "parallel_tool_calls": true
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )

        XCTAssertNil(chat["tools"])
        XCTAssertNil(chat["tool_choice"])
        XCTAssertNil(chat["parallel_tool_calls"])
    }

    func testRejectsModelsThatAreNotKnownOpenCodeGoChatModels() throws {
        for model in ["gpt-5.6-luna", "qwen3.8-max", "unknown-model"] {
            let body = try JSONSerialization.data(withJSONObject: ["model": model])
            XCTAssertThrowsError(
                try OpenCodeGoResponsesRequestConverter.convert(responseRequest: body)
            ) { error in
                XCTAssertEqual(error as? OpenCodeGoBridgeError, .unsupportedModel)
            }
        }
    }

    func testPreserveProjectionUsesOpenAIBaseURLMarkersWithoutCustomProviderAuth() throws {
        let profileID = UUID(uuidString: "C3016E28-5D7F-4E26-8A3D-0C25C4C58AF1")!
        let profile = ProviderProfile(
            id: profileID,
            name: "Preserving Chat profile",
            presetID: .openCodeGo,
            model: "glm-5.2",
            preserveSessions: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let original = """
        # User-owned settings stay intact.
        approval_policy = "never"

        [mcp_servers.example]
        command = "example-mcp"
        """

        let projected = try CodexConfigProjector().project(
            original: original,
            profile: profile
        )

        XCTAssertTrue(projected.contains(CodexConfigProjector.preserveSessionsMarker))
        XCTAssertTrue(projected.contains(CodexConfigProjector.openAIBaseURLMarker))
        XCTAssertTrue(projected.contains("model = \"\(profile.model)\""))
        XCTAssertTrue(
            projected.contains(
                "openai_base_url = \"\(ProviderCatalog.openCodeGoBridgeBaseURL)\""
            )
        )
        XCTAssertTrue(
            projected.contains(
                "\(CodexConfigProjector.preserveProfileIDMarkerPrefix)\(profileID.uuidString)"
            )
        )
        XCTAssertTrue(
            projected.contains(
                "\(CodexConfigProjector.preservePresetMarkerPrefix)openCodeGo"
            )
        )
        XCTAssertTrue(projected.contains(CodexConfigProjector.catalogPointerMarker))
        XCTAssertTrue(projected.contains("model_catalog_json = \"\(CodexModelCatalog.filename)\""))
        XCTAssertFalse(projected.contains("model_provider ="))
        XCTAssertFalse(projected.contains(CodexConfigProjector.providersBeginMarker))
        XCTAssertFalse(projected.contains("[model_providers."))
        XCTAssertFalse(projected.contains("auth.command"))
        XCTAssertFalse(projected.contains("command = \"/usr/bin/security\""))
        XCTAssertFalse(projected.contains("secret"))
        XCTAssertTrue(projected.contains("approval_policy = \"never\""))
        XCTAssertTrue(projected.contains("[mcp_servers.example]"))
    }

    func testPreserveProjectionCanReturnToCustomProviderAndRejectsForeignOpenAIBaseURL() throws {
        let preserveProfile = makeProfile(
            presetID: .openCodeGo,
            model: "glm-5.2",
            preserveSessions: true
        )
        let projected = try CodexConfigProjector().project(
            original: "approval_policy = \"never\"\n",
            profile: preserveProfile
        )
        let normalProfile = ProviderProfile(
            id: preserveProfile.id,
            name: preserveProfile.name,
            presetID: preserveProfile.presetID,
            model: preserveProfile.model,
            preserveSessions: false,
            createdAt: preserveProfile.createdAt,
            updatedAt: preserveProfile.updatedAt
        )
        let restored = try CodexConfigProjector().project(
            original: projected,
            profile: normalProfile
        )

        XCTAssertFalse(restored.contains(CodexConfigProjector.preserveSessionsMarker))
        XCTAssertFalse(restored.contains(CodexConfigProjector.openAIBaseURLMarker))
        XCTAssertFalse(restored.contains("openai_base_url ="))
        XCTAssertTrue(restored.contains("model_provider = \"\(ProviderCatalog.openCodeGoBridgeProviderID)\""))
        XCTAssertTrue(restored.contains(CodexConfigProjector.providersBeginMarker))
        XCTAssertTrue(restored.contains("[model_providers.\(ProviderCatalog.openCodeGoBridgeProviderID)]"))
        XCTAssertTrue(restored.contains("command = \"/usr/bin/security\""))

        let foreign = """
        openai_base_url = "https://foreign.example/v1"
        approval_policy = "never"
        """
        XCTAssertThrowsError(
            try CodexConfigProjector().project(
                original: foreign,
                profile: preserveProfile
            )
        ) { error in
            XCTAssertEqual(error as? CodexSwitchError, .foreignOpenAIBaseURL)
        }
    }

    func testSeparatesThinkTagsAcrossBufferedSSEChunks() throws {
        let upstream = """
        data: {"id":"chatcmpl_think","model":"glm-5.2","choices":[{"index":0,"delta":{"content":"Before <th"},"finish_reason":null}]}

        data: {"id":"chatcmpl_think","choices":[{"index":0,"delta":{"content":"ink>private reasoning"},"finish_reason":null}]}

        data: {"id":"chatcmpl_think","choices":[{"index":0,"delta":{"content":"</think> After"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.reasoning_summary_text.delta"))
        XCTAssertTrue(events.contains("private reasoning"))
        XCTAssertTrue(events.contains("Before  After"))
        XCTAssertFalse(events.contains("<think>"))
        XCTAssertFalse(events.contains("</think>"))
    }

    func testTreatsUnclosedThinkTagsAsReasoning() throws {
        let upstream = """
        {"id":"chatcmpl_unclosed","model":"glm-5.2","choices":[{"message":{"role":"assistant","content":"Visible <think>private"},"finish_reason":"stop"}]}
        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.reasoning_summary_text.delta"))
        XCTAssertTrue(events.contains("Visible "))
        XCTAssertTrue(events.contains("private"))
        XCTAssertFalse(events.contains("<think>"))
        XCTAssertFalse(events.contains("</think>"))
    }

    func testAcceptsCompactRoutesAndReturnsTypedErrorsForNonResponsesBodies() throws {
        XCTAssertTrue(OpenCodeGoBridgeRoute.accepts("/v1/responses/compact"))
        XCTAssertTrue(OpenCodeGoBridgeRoute.accepts("/responses/compact"))
        XCTAssertFalse(OpenCodeGoBridgeRoute.accepts("/v1/chat/completions"))
        XCTAssertEqual(URLSessionOpenCodeGoBridgeTransport.upstreamRequestTimeout, 60)

        XCTAssertThrowsError(
            try OpenCodeGoResponsesRequestConverter.convert(
                responseRequest: Data("{\"operation\":\"compact\"}".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? OpenCodeGoBridgeError, .invalidRequest)
        }
        XCTAssertEqual(
            OpenCodeGoBridgeErrorNormalizer.normalize(
                OpenCodeGoBridgeError.invalidRequest
            ).statusCode,
            400
        )
    }

    func testLoopbackModelsEndpointsReturnOpenAIListFromCatalogSSOT() async throws {
        let bridge = OpenCodeGoBridgeManager(port: 0)
        try bridge.ensureRunning()
        defer { bridge.stop() }

        let port = try XCTUnwrap(bridge.localPort)
        let expectedModelIDs = Set(CodexModelCatalog.bridgeModelIDs)
        var responseBodies: [Data] = []

        for path in ["/models", "/v1/models"] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
            let (data, response) = try await URLSession.shared.data(from: url)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let models = try XCTUnwrap(body["data"] as? [[String: Any]])

            XCTAssertEqual(httpResponse.statusCode, 200)
            XCTAssertEqual(body["object"] as? String, "list")
            XCTAssertEqual(
                Set(models.compactMap { $0["id"] as? String }),
                expectedModelIDs
            )
            XCTAssertTrue(models.allSatisfy { $0["object"] as? String == "model" })
            XCTAssertTrue(models.allSatisfy { $0["owned_by"] as? String == "all-in-one-codex" })
            XCTAssertTrue(models.contains { $0["id"] as? String == "deepseek-v4-flash" })
            XCTAssertTrue(models.contains { $0["id"] as? String == "deepseek-v4-pro" })
            responseBodies.append(data)
        }

        XCTAssertEqual(responseBodies.count, 2)
        XCTAssertEqual(responseBodies[0], responseBodies[1])
    }

    func testPreserveResponsesLoopbackUsesSelectedCredentialAndForwardsOnlySafeHeaders() async throws {
        let upstreamBody = Data(#"{"id":"resp_passthrough","model":"gpt-5.6-luna","output":[]}"#.utf8)
        let transport = CapturingBridgeTransport(
            response: OpenCodeGoBridgeTransportResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: upstreamBody
            )
        )
        let bridge = OpenCodeGoBridgeManager(port: 0, transport: transport)
        let profile = makeProfile(
            presetID: .openCodeGo,
            model: "gpt-5.6-luna",
            preserveSessions: true
        )
        let route = try ProviderCatalog.route(for: profile)
        bridge.configurePreservingSessions(
            route: route,
            credential: Data("selected-responses-key".utf8)
        )
        try bridge.ensureRunning()
        defer { bridge.stop() }

        let port = try XCTUnwrap(bridge.localPort)
        let requestBody = Data(#"{"model":"gpt-5.6-luna","input":"hello","stream":false}"#.utf8)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/responses"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = requestBody
        request.setValue("Bearer inbound-oauth-must-not-forward", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("zstd", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("official-account-metadata", forHTTPHeaderField: "X-Official-Account")

        let (body, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(body, upstreamBody)

        let upstreamRequest = try XCTUnwrap(transport.capturedRequest)
        XCTAssertEqual(
            upstreamRequest.url?.absoluteString,
            "\(ProviderCatalog.openCodeGoOfficialBaseURL)/responses"
        )
        XCTAssertEqual(upstreamRequest.httpBody, requestBody)
        XCTAssertEqual(
            upstreamRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer selected-responses-key"
        )
        XCTAssertNotEqual(
            upstreamRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer inbound-oauth-must-not-forward"
        )
        XCTAssertNil(upstreamRequest.value(forHTTPHeaderField: "X-Official-Account"))
        XCTAssertEqual(upstreamRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(upstreamRequest.value(forHTTPHeaderField: "Content-Encoding"), "zstd")
        XCTAssertEqual(upstreamRequest.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testPreserveChatLoopbackRejectsCompressedBodyBeforeConversion() async throws {
        let transport = CapturingBridgeTransport(
            response: OpenCodeGoBridgeTransportResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data()
            )
        )
        let bridge = OpenCodeGoBridgeManager(port: 0, transport: transport)
        let profile = makeProfile(
            presetID: .openCodeGo,
            model: "glm-5.2",
            preserveSessions: true
        )
        let route = try ProviderCatalog.route(for: profile)
        bridge.configurePreservingSessions(
            route: route,
            credential: Data("selected-chat-key".utf8)
        )
        try bridge.ensureRunning()
        defer { bridge.stop() }

        let port = try XCTUnwrap(bridge.localPort)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/responses"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("compressed-body-placeholder".utf8)
        request.setValue("Bearer inbound-oauth", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("zstd", forHTTPHeaderField: "Content-Encoding")

        let (body, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 415)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("unsupported_content_encoding"))
        XCTAssertNil(transport.capturedRequest)
    }

    func testPreserveChatLoopbackUsesSelectedCredentialAndConvertsToUpstreamChat() async throws {
        let upstreamBody = Data(#"{"id":"chatcmpl_preserve","choices":[{"message":{"role":"assistant","content":"hello from upstream"},"finish_reason":"stop"}]}"#.utf8)
        let transport = CapturingBridgeTransport(
            response: OpenCodeGoBridgeTransportResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: upstreamBody
            )
        )
        let bridge = OpenCodeGoBridgeManager(port: 0, transport: transport)
        let profile = makeProfile(
            presetID: .openCodeGo,
            model: "glm-5.2",
            preserveSessions: true
        )
        let route = try ProviderCatalog.route(for: profile)
        bridge.configurePreservingSessions(
            route: route,
            credential: Data("selected-chat-key".utf8)
        )
        try bridge.ensureRunning()
        defer { bridge.stop() }

        let port = try XCTUnwrap(bridge.localPort)
        let requestBody = Data(#"{"model":"glm-5.2","input":[{"role":"user","content":"hello"}]}"#.utf8)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/responses"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = requestBody
        request.setValue("Bearer inbound-oauth-must-not-forward", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("official-account-metadata", forHTTPHeaderField: "X-Official-Account")

        let (body, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        let sse = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(sse.contains("hello from upstream"))

        let upstreamRequest = try XCTUnwrap(transport.capturedRequest)
        XCTAssertEqual(
            upstreamRequest.url?.absoluteString,
            "\(ProviderCatalog.openCodeGoOfficialBaseURL)/chat/completions"
        )
        XCTAssertEqual(
            upstreamRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer selected-chat-key"
        )
        XCTAssertNotEqual(
            upstreamRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer inbound-oauth-must-not-forward"
        )
        XCTAssertNil(upstreamRequest.value(forHTTPHeaderField: "X-Official-Account"))
        let converted = try XCTUnwrap(
            upstreamRequest.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                as? [String: Any]
        )
        XCTAssertEqual(converted["model"] as? String, "glm-5.2")
        XCTAssertNotNil(converted["messages"] as? [[String: Any]])
    }

    func testPrepareForUseStartsOnlyForAnActiveBridgeConfiguration() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configDirectory = directoryURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("config.toml")
        let bridge = FakeBridgeManager()
        let adapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: FakeCredentialStore(),
            bridgeManager: bridge
        )

        try Data("model_provider = \"all_in_one_openrouter\"\n".utf8).write(to: configURL)
        try adapter.prepareForUse()
        XCTAssertTrue(bridge.events.isEmpty)

        try Data("model_provider = \"all_in_one_opencode_go_bridge\"\n".utf8).write(to: configURL)
        try adapter.prepareForUse()
        XCTAssertEqual(bridge.events, ["ensure"])

        let noOpAdapter: any ClientAdapter = NoopClientAdapter()
        XCTAssertNoThrow(try noOpAdapter.prepareForUse())
    }

    func testConfiguresAcceptedSocketsToSuppressSigPipe() throws {
        var descriptors: [Int32] = [0, 0]
        let created = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        XCTAssertEqual(created, 0)
        defer {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
        }

        XCTAssertTrue(OpenCodeGoBridgeSocketOptions.configureNoSigPipe(on: descriptors[0]))
        var enabled: Int32 = 0
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        let inspected = withUnsafeMutablePointer(to: &enabled) { pointer in
            Darwin.getsockopt(
                descriptors[0],
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                &optionLength
            )
        }
        XCTAssertEqual(inspected, 0)
        XCTAssertEqual(enabled, 1)
    }

    func testCustomToolRoundTripsThroughChatAsCustomToolCall() throws {
        let request = """
        {
          "model": "glm-5.2",
          "tools": [{
            "type": "custom",
            "name": "run_shell",
            "description": "Runs a shell command."
          }]
        }
        """
        let requestConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestConversion.body) as? [String: Any]
        )
        let function = try XCTUnwrap(
            (chat["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any]
        )
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "run_shell")
        XCTAssertEqual(parameters["required"] as? [String], ["input"])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)

        let upstream = """
        {"id":"chatcmpl_custom","choices":[{"message":{"tool_calls":[{"id":"call_shell","type":"function","function":{"name":"run_shell","arguments":"{\\"input\\":\\"pwd\\"}"}}]},"finish_reason":"tool_calls"}]}
        """
        let responseConversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2",
            toolContext: requestConversion.toolContext
        )
        let events = try XCTUnwrap(String(data: responseConversion.sse, encoding: .utf8))
        XCTAssertTrue(events.contains("event: response.custom_tool_call_input.delta"))
        XCTAssertTrue(events.contains("event: response.custom_tool_call_input.done"))
        XCTAssertTrue(events.contains("\"type\":\"custom_tool_call\""))
        XCTAssertTrue(events.contains("\"name\":\"run_shell\""))
        XCTAssertTrue(events.contains("\"input\":\"pwd\""))
        XCTAssertTrue(events.contains("event: response.output_item.done"))
    }

    func testCoalescesFragmentedCustomToolArguments() throws {
        let context = OpenCodeGoToolContext(mappings: [
            OpenCodeGoToolMapping(
                chatName: "write_file",
                responseName: "write_file",
                kind: .custom
            )
        ])
        let upstream = #"""
        data: {"id":"chatcmpl_custom_fragment","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_write","function":{"name":"write_file","arguments":"{\"input\":\"hel"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl_custom_fragment","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"lo\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """#
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2",
            toolContext: context
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))
        XCTAssertTrue(events.contains("\"input\":\"hello\""))
        XCTAssertTrue(events.contains("event: response.custom_tool_call_input.done"))
    }

    func testFlattensNamespacedToolsAndHashesLongNamesReversibly() throws {
        let longName = String(repeating: "a", count: 80)
        let request: [String: Any] = [
            "model": "glm-5.2",
            "tools": [[
                "type": "custom",
                "namespace": "filesystem",
                "name": "read"
            ], [
                "type": "custom",
                "name": longName
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let first = try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
        let second = try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
        let mappings = first.toolContext.mappings
        let namespaced = try XCTUnwrap(mappings.first { $0.responseName == "read" })
        let long = try XCTUnwrap(mappings.first { $0.responseName == longName })

        XCTAssertEqual(namespaced.chatName, "filesystem__read")
        XCTAssertEqual(namespaced.namespace, "filesystem")
        XCTAssertLessThanOrEqual(long.chatName.count, 64)
        XCTAssertEqual(long.chatName, second.toolContext.mapping(forChatName: long.chatName)?.chatName)
        XCTAssertEqual(first.toolContext.mapping(forChatName: long.chatName)?.responseName, longName)
    }

    func testToolSearchUsesSyntheticTypedToolCall() throws {
        let request = """
        {
          "model": "glm-5.2",
          "tools": [{"type": "tool_search", "namespace": "docs"}]
        }
        """
        let requestConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let mapping = try XCTUnwrap(requestConversion.toolContext.mappings.first)
        XCTAssertEqual(mapping.kind, .toolSearch)
        XCTAssertEqual(mapping.chatName, "docs__docs_search")

        let upstream = """
        {"id":"chatcmpl_search","choices":[{"message":{"tool_calls":[{"id":"call_search","type":"function","function":{"name":"docs__docs_search","arguments":"{\\"input\\":\\"Codex tools\\"}"}}]},"finish_reason":"tool_calls"}]}
        """
        let responseConversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2",
            toolContext: requestConversion.toolContext
        )
        let events = try XCTUnwrap(String(data: responseConversion.sse, encoding: .utf8))
        XCTAssertTrue(events.contains("\"type\":\"tool_search_call\""))
        XCTAssertTrue(events.contains("event: response.tool_search_call_input.done"))
        XCTAssertTrue(events.contains("\"input\":\"Codex tools\""))
    }

    func testCustomToolCallAndOutputHistoryBecomeChatToolMessages() throws {
        let request = """
        {
          "model": "glm-5.2",
          "tools": [{"type": "custom", "name": "execute"}],
          "input": [
            {"type": "custom_tool_call", "call_id": "call_execute", "name": "execute", "input": "echo hello"},
            {"type": "custom_tool_call_output", "call_id": "call_execute", "output": "hello"}
          ]
        }
        """
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        let toolCall = try XCTUnwrap(
            (messages[0]["tool_calls"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(
            ((toolCall["function"] as? [String: Any])?["arguments"] as? String),
            "{\"input\":\"echo hello\"}"
        )
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "call_execute")
        XCTAssertEqual(messages[1]["content"] as? String, "hello")
    }

    func testSystemAndDeveloperMessagesPrecedeCachedToolHistory() throws {
        let cache = OpenCodeGoToolCallCache()
        cache.store(
            responseID: "resp_prior",
            toolCalls: [OpenCodeGoToolCall(id: "call_lookup", name: "lookup", arguments: "{}")]
        )
        let request = """
        {
          "model": "glm-5.2",
          "previous_response_id": "resp_prior",
          "input": [
            {"type": "function_call_output", "call_id": "call_lookup", "output": "result"},
            {"role": "developer", "content": "Developer instructions."},
            {"role": "system", "content": "System instructions."}
          ]
        }
        """
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8),
            toolCallCache: cache
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, [
            "system", "system", "assistant", "tool"
        ])
        XCTAssertEqual(messages[2]["tool_calls"] as? [[String: Any]] != nil, true)
        XCTAssertEqual(messages[3]["content"] as? String, "result")
    }

    func testRejectsInvalidCustomToolNamesAndSchemas() throws {
        for tool in [
            ["type": "custom", "name": "   "] as [String: Any],
            ["type": "custom", "name": "valid", "parameters": "not-an-object"] as [String: Any]
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "model": "glm-5.2",
                "tools": [tool]
            ])
            XCTAssertThrowsError(
                try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
            ) { error in
                XCTAssertEqual(error as? OpenCodeGoBridgeError, .invalidRequest)
            }
        }
    }

    private func makeProfile(
        presetID: ProviderPresetID,
        model: String? = nil,
        preserveSessions: Bool = false
    ) -> ProviderProfile {
        ProviderProfile(
            name: "Test profile",
            presetID: presetID,
            model: model,
            preserveSessions: preserveSessions,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllInOneCodexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func makeCodexConfigurationURL(in directoryURL: URL) throws -> URL {
        let configDirectoryURL = directoryURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectoryURL,
            withIntermediateDirectories: true
        )
        return configDirectoryURL.appendingPathComponent("config.toml")
    }
}

private final class FakeCredentialStore: CredentialStoring {
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

private final class FakeBridgeManager: OpenCodeGoBridgeManaging {
    var events: [String] = []
    var onEnsure: (() throws -> Void)?

    func ensureRunning() throws {
        events.append("ensure")
        try onEnsure?()
    }

    func stop() {
        events.append("stop")
    }
}

private final class ConfigurableFakeBridgeManager: OpenCodeGoBridgeManaging, OpenCodeGoBridgeConfiguring {
    var events: [String] = []
    var configuredRoute: ProviderRoute?
    var configuredCredential: Data?
    var onEnsure: (() throws -> Void)?

    func configureLegacyChatMode() {
        events.append("configure-legacy")
    }

    func configurePreservingSessions(route: ProviderRoute, credential: Data) {
        events.append("configure-preserve")
        configuredRoute = route
        configuredCredential = credential
    }

    func ensureRunning() throws {
        events.append("ensure")
        try onEnsure?()
    }

    func stop() {
        events.append("stop")
    }
}

private final class CapturingBridgeTransport: OpenCodeGoBridgeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let response: OpenCodeGoBridgeTransportResponse
    private var requestStorage: URLRequest?

    init(response: OpenCodeGoBridgeTransportResponse) {
        self.response = response
    }

    var capturedRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func execute(_ request: URLRequest) async throws -> OpenCodeGoBridgeTransportResponse {
        record(request)
        return response
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        requestStorage = request
        lock.unlock()
    }
}

private struct NoopClientAdapter: ClientAdapter {
    func preview(profile: ProviderProfile) throws -> SwitchPreview {
        SwitchPreview(original: "", projected: "", summary: "")
    }

    func apply(profile: ProviderProfile) throws -> SwitchReceipt {
        SwitchReceipt(
            backupURL: URL(fileURLWithPath: "/tmp/noop"),
            beforeHash: "",
            afterHash: "",
            timestamp: .distantPast,
            originalConfigExisted: false
        )
    }

    func undo(_ receipt: SwitchReceipt) throws {}
}

private final class OneShotConfigurationWriteFailure: CodexAtomicWriteIntercepting {
    private let configURL: URL
    private var shouldFail = true

    init(configURL: URL) {
        self.configURL = configURL.standardizedFileURL
    }

    func willWriteAtomically(to destination: URL) throws {
        guard
            shouldFail,
            destination.standardizedFileURL == configURL
        else {
            return
        }
        shouldFail = false
        throw TestAtomicWriteError.intentionalFailure
    }
}

private enum TestAtomicWriteError: Error {
    case intentionalFailure
}
