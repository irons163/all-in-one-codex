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

    func testConvertsRemoteCompactionV2RequestWithoutResponsesOnlyTools() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "stream": true,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Keep this decision."]]
                ],
                ["type": "compaction_trigger"]
            ],
            "tools": [[
                "type": "namespace",
                "name": "mcp__example",
                "description": "Responses-only namespace fixture.",
                "tools": [[
                    "type": "function",
                    "name": "lookup",
                    "description": "Lookup fixture.",
                    "strict": false,
                    "parameters": ["type": "object", "properties": [String: Any]()]
                ]]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])

        XCTAssertEqual(conversion.outputMode, .compaction)
        XCTAssertNil(chat["tools"])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertTrue(
            (messages.last?["content"] as? String)?.contains("continuation summary") == true
        )
    }

    func testRestoresBridgeCompactionEnvelopeIntoFollowingChatRequest() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "input": [
                [
                    "type": "compaction",
                    "encrypted_content": OpenCodeGoCompactionEnvelope.wrap("Decision: retain session IDs.")
                ],
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Continue."]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])

        XCTAssertEqual(conversion.outputMode, .standard)
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertTrue(
            (messages.first?["content"] as? String)?.contains("retain session IDs") == true
        )
        XCTAssertEqual(messages.last?["role"] as? String, "user")
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

    func testDeepSeekAssistantToolHistoryAddsEmptyContentAndReasoningContent() throws {
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "input": [[
                "role": "assistant",
                "content": [[
                    "type": "function_call",
                    "call_id": "call_lookup",
                    "name": "lookup_weather",
                    "arguments": "{\"city\":\"Taipei\"}"
                ]]
            ]]
        ]

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let message = try XCTUnwrap(
            (chat["messages"] as? [[String: Any]])?.first
        )

        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertNotNil(message["tool_calls"] as? [[String: Any]])
        XCTAssertTrue(message.keys.contains("content"))
        XCTAssertEqual(message["content"] as? String, "")
        XCTAssertTrue(message.keys.contains("reasoning_content"))
        XCTAssertEqual(message["reasoning_content"] as? String, "tool call")
    }

    func testDeepSeekFullAssistantHistoryExtractsContentPartReasoning() throws {
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "input": [[
                "role": "assistant",
                "content": [
                    ["type": "reasoning", "text": "I should inspect the prior tool output."],
                    ["type": "output_text", "text": "I found the result."]
                ]
            ]]
        ]

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let message = try XCTUnwrap(
            (chat["messages"] as? [[String: Any]])?.first
        )
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])

        XCTAssertEqual(
            message["reasoning_content"] as? String,
            "I should inspect the prior tool output."
        )
        XCTAssertEqual(content.map { $0["text"] as? String }, ["I found the result."])
    }

    func testDeepSeekStandaloneFunctionAndCustomCallsAddEmptyAssistantFields() throws {
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "input": [
                [
                    "type": "function_call",
                    "call_id": "call_lookup",
                    "name": "lookup_weather",
                    "arguments": "{}"
                ],
                [
                    "type": "custom_tool_call",
                    "call_id": "call_custom_lookup",
                    "name": "lookup_custom",
                    "input": "weather"
                ]
            ]
        ]

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 2)
        for message in messages {
            XCTAssertEqual(message["role"] as? String, "assistant")
            XCTAssertEqual(message["content"] as? String, "")
            XCTAssertEqual(message["reasoning_content"] as? String, "tool call")
        }
    }

    func testDeepSeekStandaloneReasoningSummaryAttachesToFollowingToolCall() throws {
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "input": [
                [
                    "type": "reasoning",
                    "summary": [[
                        "type": "summary_text",
                        "text": "I should inspect the current goal before updating it."
                    ]]
                ],
                [
                    "type": "function_call",
                    "call_id": "call_goal",
                    "name": "get_goal",
                    "arguments": "{}"
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_goal",
                    "output": #"{"status":"active"}"#
                ]
            ],
            "tools": [[
                "type": "function",
                "name": "get_goal",
                "parameters": [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            ]]
        ]

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        let toolCall = try XCTUnwrap(
            (messages.first?["tool_calls"] as? [[String: Any]])?.first
        )

        XCTAssertEqual(messages.map { $0["role"] as? String }, ["assistant", "tool"])
        XCTAssertEqual(messages.first?["content"] as? String, "")
        XCTAssertEqual(
            messages.first?["reasoning_content"] as? String,
            "I should inspect the current goal before updating it."
        )
        XCTAssertEqual(
            (toolCall["function"] as? [String: Any])?["name"] as? String,
            "get_goal"
        )
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call_goal")
    }

    func testGLMToolHistoryBackfillsThinkingPlaceholderLikeCCSwitch() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "input": [
                [
                    "role": "assistant",
                    "content": [[
                        "type": "function_call",
                        "call_id": "call_message_lookup",
                        "name": "lookup_weather",
                        "arguments": "{}"
                    ]]
                ],
                [
                    "type": "function_call",
                    "call_id": "call_standalone_lookup",
                    "name": "lookup_weather",
                    "arguments": "{}"
                ]
            ]
        ]

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 2)
        for message in messages {
            XCTAssertEqual(message["content"] as? String, "")
            XCTAssertEqual(message["reasoning_content"] as? String, "tool call")
        }
        XCTAssertEqual(
            (chat["thinking"] as? [String: Any])?["type"] as? String,
            "enabled"
        )
    }

    func testKimiToolHistoryBackfillsThinkingPlaceholder() throws {
        let request: [String: Any] = [
            "model": "kimi-k2.7-code",
            "input": [[
                "type": "function_call",
                "call_id": "call_kimi",
                "name": "lookup_weather",
                "arguments": "{}"
            ]]
        ]
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let message = try XCTUnwrap((chat["messages"] as? [[String: Any]])?.first)
        XCTAssertEqual(message["reasoning_content"] as? String, "tool call")
        XCTAssertEqual(message["content"] as? String, "")
        XCTAssertEqual(
            (chat["thinking"] as? [String: Any])?["type"] as? String,
            "enabled"
        )
    }

    func testIncrementalChatSSEParserReassemblesFragmentedEvents() throws {
        var parser = OpenCodeGoIncrementalChatSSEParser()
        let first = try parser.push(Data("data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"content\":\"He\"}}]}\n".utf8))
        XCTAssertTrue(first.isEmpty)
        let second = try parser.push(Data("\ndata: {\"choices\":[{\"delta\":{\"content\":\"llo\"},\"finish_reason\":\"stop\"}]}\n\n".utf8))
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(
            ((second[0]["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String,
            "He"
        )
        let early = try OpenCodeGoStreamingChatBridge.earlyLifecycleSSE(
            responseID: "resp_stream_test",
            model: "glm-5.2"
        )
        let earlyText = String(data: early, encoding: .utf8) ?? ""
        XCTAssertTrue(earlyText.contains("event: response.created"))
        XCTAssertTrue(earlyText.contains("event: response.in_progress"))
        let stripped = OpenCodeGoStreamingChatBridge.stripLeadingLifecycle(from: early)
        XCTAssertTrue(stripped.isEmpty)
    }

    func testDeepSeekReasoningEffortMapsToThinkingToggleOnly() throws {
        let cases: [([String: Any], String)] = [
            (["reasoning": ["effort": "none"]], "disabled"),
            (["reasoning_effort": "low"], "enabled"),
            (["reasoning": ["effort": "medium"]], "enabled"),
            (["reasoning": ["effort": "xhigh"]], "enabled"),
            (["reasoning_effort": "max"], "enabled")
        ]

        for (settings, expectedThinkingType) in cases {
            var request: [String: Any] = [
                "model": "deepseek-v4-flash",
                "input": "What is the weather?"
            ]
            settings.forEach { request[$0.key] = $0.value }

            let conversion = try OpenCodeGoResponsesRequestConverter.convert(
                responseRequest: JSONSerialization.data(withJSONObject: request)
            )
            let chat = try XCTUnwrap(
                JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
            )
            let thinking = try XCTUnwrap(chat["thinking"] as? [String: Any])

            XCTAssertEqual(thinking["type"] as? String, expectedThinkingType)
            // OpenCode Go rejected first-turn requests that also forwarded
            // `reasoning_effort`; keep the Chat body on the thinking toggle.
            XCTAssertNil(chat["reasoning_effort"])
            XCTAssertNil(chat["reasoning"])
        }
    }

    func testDeepSeekGoalToolPayloadUsesNestedSchemaAndCompatibleControls() throws {
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "input": "Create the active goal.",
            "tools": [[
                "type": "function",
                "function": [
                    "name": "create_goal",
                    "description": "Create the active goal.",
                    "parameters": [
                        "type": NSNull(),
                        "properties": NSNull()
                    ]
                ]
            ]],
            "tool_choice": ["type": "function", "name": "create_goal"],
            "parallel_tool_calls": true,
            "max_output_tokens": 512,
            "response_format": ["type": "json_object"],
            "reasoning": ["effort": "high"],
            "stream": true
        ]

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let function = try XCTUnwrap(
            (chat["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any]
        )
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "create_goal")
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertNotNil(parameters["properties"] as? [String: Any])
        // Thinking mode cannot force a function tool_choice; coerce to auto.
        XCTAssertEqual(chat["tool_choice"] as? String, "auto")
        XCTAssertNil(chat["parallel_tool_calls"])
        XCTAssertEqual(chat["max_tokens"] as? Int, 512)
        XCTAssertEqual(
            (chat["stream_options"] as? [String: Any])?["include_usage"] as? Bool,
            true
        )
        // DeepSeek rejects json_object response_format without "json" in prompt.
        XCTAssertNil(chat["response_format"])
        XCTAssertEqual(
            (chat["thinking"] as? [String: Any])?["type"] as? String,
            "enabled"
        )
        XCTAssertNil(chat["reasoning_effort"])
    }

    func testGoalToolsRoundTripThroughDeepSeekToolHistory() throws {
        let goalTools: [[String: Any]] = [
            [
                "type": "function",
                "name": "get_goal",
                "description": "Get the current goal.",
                "parameters": [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String](),
                    "additionalProperties": false
                ],
                "strict": false
            ],
            [
                "type": "function",
                "name": "create_goal",
                "description": "Create a goal.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "objective": ["type": "string"],
                        "token_budget": ["type": "integer"]
                    ],
                    "required": ["objective"],
                    "additionalProperties": false
                ],
                "strict": false
            ],
            [
                "type": "function",
                "name": "update_goal",
                "description": "Update a goal.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "status": [
                            "type": "string",
                            "enum": ["complete", "blocked"]
                        ]
                    ],
                    "required": ["status"],
                    "additionalProperties": false
                ],
                "strict": false
            ]
        ]
        let firstRequest: [String: Any] = [
            "model": "deepseek-v4-flash",
            "input": "Start the requested goal.",
            "tools": goalTools,
            "stream": true
        ]

        let firstConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: firstRequest)
        )
        let firstChat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstConversion.body) as? [String: Any]
        )
        let convertedTools = try XCTUnwrap(firstChat["tools"] as? [[String: Any]])
        XCTAssertEqual(convertedTools.count, goalTools.count)
        for (index, convertedTool) in convertedTools.enumerated() {
            let sourceTool = goalTools[index]
            let function = try XCTUnwrap(convertedTool["function"] as? [String: Any])
            let sourceParameters = try XCTUnwrap(sourceTool["parameters"] as? [String: Any])
            let convertedParameters = try XCTUnwrap(function["parameters"] as? [String: Any])

            XCTAssertEqual(convertedTool["type"] as? String, "function")
            XCTAssertNil(convertedTool["name"])
            XCTAssertEqual(function["name"] as? String, sourceTool["name"] as? String)
            XCTAssertEqual(function["strict"] as? Bool, sourceTool["strict"] as? Bool)
            XCTAssertEqual(
                try JSONSerialization.data(withJSONObject: convertedParameters, options: [.sortedKeys]),
                try JSONSerialization.data(withJSONObject: sourceParameters, options: [.sortedKeys])
            )
        }

        let upstream = """
        data: {"id":"chatcmpl_goal","model":"deepseek-v4-flash","choices":[{"index":0,"delta":{"reasoning_content":"","tool_calls":[{"index":0,"id":"call_goal","type":"function","function":{"name":"get_goal","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        let responseConversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "deepseek-v4-flash",
            toolContext: firstConversion.toolContext
        )
        let cache = OpenCodeGoToolCallCache()
        cache.store(
            responseID: responseConversion.responseID,
            toolCalls: responseConversion.toolCalls,
            reasoningContent: responseConversion.reasoningContent,
            reasoningContentPresent: responseConversion.reasoningContentPresent
        )

        let continuation: [String: Any] = [
            "model": "deepseek-v4-flash",
            "previous_response_id": responseConversion.responseID,
            "input": [[
                "type": "function_call_output",
                "call_id": "call_goal",
                "output": "{\"status\":\"active\"}"
            ]],
            "tools": goalTools,
            "stream": true
        ]
        let continuationConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: continuation),
            toolCallCache: cache
        )
        let continuationChat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: continuationConversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(
            continuationChat["messages"] as? [[String: Any]]
        )
        let assistant = try XCTUnwrap(messages.first)
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        XCTAssertEqual(assistant["content"] as? String, "")
        XCTAssertTrue(assistant.keys.contains("reasoning_content"))
        XCTAssertEqual(assistant["reasoning_content"] as? String, "tool call")
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call_goal")
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

    func testConvertsChatSummaryIntoRemoteCompactionV2OutputItem() throws {
        let upstream = """
        {"id":"chatcmpl_compact","model":"glm-5.2","created":1700000000,"choices":[{"message":{"role":"assistant","content":"Goal: preserve the active session. Next: retry the bridge."},"finish_reason":"stop"}],"usage":{"prompt_tokens":40,"completion_tokens":12,"total_tokens":52}}
        """

        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2",
            outputMode: .compaction
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.output_item.added"))
        XCTAssertTrue(events.contains("event: response.output_item.done"))
        XCTAssertTrue(events.contains("\"type\":\"compaction\""))
        XCTAssertTrue(events.contains("all-in-one-codex-chat-summary-v1"))
        XCTAssertTrue(events.contains("preserve the active session"))
        XCTAssertFalse(events.contains("\"type\":\"message\""))
        XCTAssertTrue(events.contains("event: response.completed"))
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

    func testDeepSeekToolCallWithoutReasoningReplaysExplicitEmptyReasoningContent() throws {
        let upstream = """
        {
          "id": "chatcmpl_deepseek_empty_reasoning",
          "model": "deepseek-v4-flash",
          "choices": [{
            "message": {
              "role": "assistant",
              "tool_calls": [{
                "id": "call_lookup",
                "type": "function",
                "function": {"name": "lookup_weather", "arguments": "{}"}
              }]
            },
            "finish_reason": "tool_calls"
          }]
        }
        """
        let responseConversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "deepseek-v4-flash"
        )
        let cache = OpenCodeGoToolCallCache()
        cache.store(
            responseID: responseConversion.responseID,
            toolCalls: responseConversion.toolCalls,
            reasoningContent: responseConversion.reasoningContent
        )
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "previous_response_id": responseConversion.responseID,
            "input": [[
                "type": "function_call_output",
                "call_id": "call_lookup",
                "output": "Sunny"
            ]]
        ]
        let requestConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request),
            toolCallCache: cache
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestConversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])

        XCTAssertEqual(responseConversion.reasoningContent, "")
        XCTAssertTrue(responseConversion.reasoningContentPresent)
        XCTAssertTrue(cache.history(for: responseConversion.responseID)?.reasoningContentPresent == true)
        XCTAssertTrue(messages[0].keys.contains("content"))
        XCTAssertEqual(messages[0]["content"] as? String, "")
        XCTAssertTrue(messages[0].keys.contains("reasoning_content"))
        // Empty upstream reasoning is not valid on DeepSeek tool-call replay;
        // match cc-switch and inject a non-empty placeholder.
        XCTAssertEqual(messages[0]["reasoning_content"] as? String, "tool call")
    }

    func testDeepSeekToolCallWithReasoningRoundTripsContent() throws {
        let upstream = """
        {
          "id": "chatcmpl_deepseek_reasoning",
          "model": "deepseek-v4-flash",
          "choices": [{
            "message": {
              "role": "assistant",
              "reasoning_content": "I should inspect the weather source.",
              "tool_calls": [{
                "id": "call_lookup",
                "type": "function",
                "function": {"name": "lookup_weather", "arguments": "{}"}
              }]
            },
            "finish_reason": "tool_calls"
          }]
        }
        """
        let responseConversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "deepseek-v4-flash"
        )
        let cache = OpenCodeGoToolCallCache()
        cache.store(
            responseID: responseConversion.responseID,
            toolCalls: responseConversion.toolCalls,
            reasoningContent: responseConversion.reasoningContent
        )
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "previous_response_id": responseConversion.responseID,
            "input": [[
                "type": "function_call_output",
                "call_id": "call_lookup",
                "output": "Sunny"
            ]]
        ]
        let requestConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request),
            toolCallCache: cache
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestConversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])

        XCTAssertTrue(responseConversion.reasoningContentPresent)
        XCTAssertEqual(
            messages[0]["reasoning_content"] as? String,
            "I should inspect the weather source."
        )
    }

    func testPreservesExplicitEmptyAssistantReasoningContentWithoutSynthesizingIt() throws {
        let explicitRequest: [String: Any] = [
            "model": "glm-5.2",
            "input": [[
                "role": "assistant",
                "content": "I will continue.",
                "reasoning_content": ""
            ]]
        ]
        let explicitConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: explicitRequest)
        )
        let explicitChat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: explicitConversion.body) as? [String: Any]
        )
        let explicitMessage = try XCTUnwrap(
            (explicitChat["messages"] as? [[String: Any]])?.first
        )

        let ordinaryRequest: [String: Any] = [
            "model": "glm-5.2",
            "input": [["role": "assistant", "content": "I will continue."]]
        ]
        let ordinaryConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: ordinaryRequest)
        )
        let ordinaryChat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ordinaryConversion.body) as? [String: Any]
        )
        let ordinaryMessage = try XCTUnwrap(
            (ordinaryChat["messages"] as? [[String: Any]])?.first
        )

        XCTAssertTrue(explicitMessage.keys.contains("reasoning_content"))
        XCTAssertEqual(explicitMessage["reasoning_content"] as? String, "")
        XCTAssertFalse(ordinaryMessage.keys.contains("reasoning_content"))
    }

    func testCacheDoesNotCreateHistoryForOrdinaryTextResponses() throws {
        let upstream = """
        {
          "id": "chatcmpl_text_reasoning",
          "model": "deepseek-v4-flash",
          "choices": [{
            "message": {
              "role": "assistant",
              "content": "The weather is sunny.",
              "reasoning_content": "No tool is required."
            },
            "finish_reason": "stop"
          }]
        }
        """
        let responseConversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "deepseek-v4-flash"
        )
        let cache = OpenCodeGoToolCallCache()
        cache.store(
            responseID: responseConversion.responseID,
            toolCalls: responseConversion.toolCalls,
            reasoningContent: responseConversion.reasoningContent
        )
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "previous_response_id": responseConversion.responseID,
            "input": "What next?"
        ]
        let requestConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request),
            toolCallCache: cache
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestConversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])

        XCTAssertTrue(responseConversion.toolCalls.isEmpty)
        XCTAssertNil(cache.history(for: responseConversion.responseID))
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user"])
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

    func testClassifiesReasoningContentRequirementWithoutLeakingUpstreamFields() {
        let secret = "fixture-secret-reasoning-content"
        let upstreamBody = Data(
            """
            {
              "error": {
                "message": "Missing required parameter: reasoning_content. \(secret)",
                "type": "invalid_request_error",
                "code": "missing_reasoning_content",
                "param": "reasoning_content"
              }
            }
            """.utf8
        )

        let normalized = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 400,
            upstreamErrorBody: upstreamBody
        )
        let failure = OpenCodeGoResponsesEventEncoder.failure(
            responseID: "resp_fixture",
            model: "deepseek-v4-flash",
            normalizedError: normalized
        )
        let events = String(decoding: failure, as: UTF8.self)

        XCTAssertEqual(normalized.statusCode, 400)
        XCTAssertEqual(normalized.code, "upstream_reasoning_content_required")
        XCTAssertEqual(
            normalized.message,
            "OpenCode Go requires reasoning content for this request."
        )
        XCTAssertTrue(events.contains("event: response.failed"))
        XCTAssertTrue(events.contains("upstream_reasoning_content_required"))
        XCTAssertFalse(events.contains(secret))
        XCTAssertFalse(events.contains("Missing required parameter"))
    }

    func testClassifiesUnsupportedToolSchemaWithoutLeakingUpstreamFields() {
        let secret = "fixture-secret-tool-schema"
        let upstreamBody = Data(
            """
            {
              "error": {
                "message": "Unsupported parameter tools[0].function.parameters. \(secret)",
                "type": "invalid_request_error",
                "code": "unsupported_parameter",
                "param": "tools[0].function.parameters"
              }
            }
            """.utf8
        )

        let normalized = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 400,
            upstreamErrorBody: upstreamBody
        )

        XCTAssertEqual(normalized.statusCode, 400)
        XCTAssertEqual(
            normalized.code,
            "upstream_unsupported_parameter_or_tool_schema"
        )
        XCTAssertEqual(
            normalized.message,
            "OpenCode Go rejected an unsupported parameter or tool schema."
        )
        XCTAssertFalse(normalized.message.contains(secret))
        XCTAssertFalse(normalized.message.contains("tools[0]"))
    }

    func testClassifiesOpaque400WithoutLeakingUpstreamBody() {
        let secret = "fixture-secret-malformed-upstream"
        let normalized = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 400,
            upstreamErrorBody: Data("not-json-\(secret)".utf8),
            model: "deepseek-v4-flash"
        )

        XCTAssertEqual(normalized.statusCode, 400)
        XCTAssertEqual(normalized.code, "upstream_invalid_request_opaque_http_400")
        XCTAssertEqual(
            normalized.message,
            "OpenCode Go rejected the converted request (HTTP 400; upstream detail unavailable)."
        )
        XCTAssertNil(normalized.providerStatus)
        XCTAssertFalse(normalized.message.contains(secret))
    }

    func testFallsBackToGenericSanitizedErrorForUnknownStructuredUpstreamBody() {
        let secret = "fixture-secret-unknown-upstream"
        let upstreamBody = Data(
            """
            {
              "error": {
                "message": "Unrelated provider failure \(secret)",
                "type": "invalid_request_error",
                "code": "unexpected_provider_code",
                "param": "unrelated"
              }
            }
            """.utf8
        )

        let normalized = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 400,
            upstreamErrorBody: upstreamBody
        )

        XCTAssertEqual(normalized.statusCode, 400)
        XCTAssertEqual(normalized.code, "upstream_invalid_request")
        XCTAssertEqual(
            normalized.message,
            "OpenCode Go rejected the converted request."
        )
        XCTAssertFalse(normalized.message.contains(secret))
    }

    func testClassifiesDeepSeekFlashFiveHundredAsProviderLaneUnavailable() {
        let secret = "fixture-secret-flash-lane"
        let flash = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 500,
            upstreamErrorBody: Data(secret.utf8),
            model: "deepseek-v4-flash"
        )
        let otherModel = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 500,
            upstreamErrorBody: Data(secret.utf8),
            model: "deepseek-v4-pro"
        )

        XCTAssertEqual(flash.statusCode, 502)
        XCTAssertEqual(flash.code, "upstream_deepseek_v4_flash_lane_unavailable")
        XCTAssertEqual(flash.providerStatus, .deepSeekV4FlashLaneUnavailable)
        XCTAssertFalse(flash.message.contains(secret))
        XCTAssertEqual(otherModel.code, "upstream_unavailable")
        XCTAssertNil(otherModel.providerStatus)
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
        let requestBody = Data(#"{"model":"glm-5.2","input":[{"role":"user","content":"hello"}],"tools":[{"type":"namespace","name":"mcp__browser","tools":[{"type":"function","name":"navigate","parameters":{"type":"object","properties":{}}}]},{"type":"web_search"}]}"#.utf8)
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
        let convertedTools = try XCTUnwrap(converted["tools"] as? [[String: Any]])
        XCTAssertEqual(convertedTools.count, 1)
        XCTAssertEqual(
            ((convertedTools[0]["function"] as? [String: Any])?["name"] as? String),
            "mcp__browser__navigate"
        )
    }

    func testPreserveChatLoopbackRoundTripsRemoteCompactionV2() async throws {
        let upstreamBody = Data(
            #"{"id":"chatcmpl_compact_bridge","choices":[{"message":{"role":"assistant","content":"Goal: keep the current session. Next: continue the task."},"finish_reason":"stop"}]}"#.utf8
        )
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
        bridge.configurePreservingSessions(
            route: try ProviderCatalog.route(for: profile),
            credential: Data("selected-chat-key".utf8)
        )
        try bridge.ensureRunning()
        defer { bridge.stop() }

        let requestObject: [String: Any] = [
            "model": "glm-5.2",
            "stream": true,
            "input": [
                ["type": "message", "role": "user", "content": "Keep this goal."],
                ["type": "compaction_trigger"]
            ],
            "tools": [[
                "type": "namespace",
                "name": "mcp__fixture",
                "description": "Responses-only fixture.",
                "tools": [[String: Any]]()
            ]]
        ]
        let port = try XCTUnwrap(bridge.localPort)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/responses"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: requestObject)
        request.setValue("Bearer inbound-oauth", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (body, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let sse = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertTrue(sse.contains("event: response.output_item.done"))
        XCTAssertTrue(sse.contains("\"type\":\"compaction\""))
        XCTAssertTrue(sse.contains("all-in-one-codex-chat-summary-v1"))
        XCTAssertFalse(sse.contains("\"type\":\"message\""))

        let upstreamRequest = try XCTUnwrap(transport.capturedRequest)
        let converted = try XCTUnwrap(
            upstreamRequest.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                as? [String: Any]
        )
        XCTAssertNil(converted["tools"])
        XCTAssertTrue(
            ((converted["messages"] as? [[String: Any]])?.last?["content"] as? String)?
                .contains("continuation summary") == true
        )
    }

    func testLoopbackSerializesSameSessionWithoutBlockingOtherGoalSessions() async throws {
        let finalResponse = OpenCodeGoBridgeTransportResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(
                #"{"id":"chatcmpl_goal_final","model":"deepseek-v4-flash","choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}"#.utf8
            )
        )
        let transport = BlockingBridgeTransport(
            responses: [
                "same-first": OpenCodeGoBridgeTransportResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: Data(
                        #"{"id":"chatcmpl_goal_first","model":"deepseek-v4-flash","choices":[{"message":{"role":"assistant","reasoning_content":"","tool_calls":[{"id":"call_goal","type":"function","function":{"name":"get_goal","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#.utf8
                    )
                ),
                "same-second": finalResponse,
                "other-session": finalResponse
            ]
        )
        let coordinator = OpenCodeGoSessionRequestCoordinator()
        let bridge = OpenCodeGoBridgeManager(
            port: 0,
            transport: transport,
            sessionRequestCoordinator: coordinator
        )
        try bridge.ensureRunning()
        defer { bridge.stop() }

        let port = try XCTUnwrap(bridge.localPort)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/responses"))
        let goalTools: [[String: Any]] = [[
            "type": "function",
            "name": "get_goal",
            "description": "Read the active goal.",
            "parameters": [
                "type": "object",
                "properties": [String: Any](),
                "additionalProperties": false
            ]
        ]]

        func makeGoalRequest(
            sessionID: String,
            tag: String,
            previousResponseID: String? = nil
        ) throws -> URLRequest {
            var requestObject: [String: Any] = [
                "model": "deepseek-v4-flash",
                "tools": goalTools
            ]
            if let previousResponseID {
                requestObject["previous_response_id"] = previousResponseID
                requestObject["input"] = [
                    [
                        "type": "function_call_output",
                        "call_id": "call_goal",
                        "output": #"{"status":"active"}"#
                    ],
                    [
                        "role": "user",
                        "content": tag
                    ]
                ]
            } else {
                requestObject["input"] = tag
            }
            let requestBody = try JSONSerialization.data(withJSONObject: requestObject)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = requestBody
            request.timeoutInterval = 2
            request.setValue("Bearer inbound-oauth", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(sessionID, forHTTPHeaderField: "Session-Id")
            return request
        }

        let firstRequest = try makeGoalRequest(
            sessionID: "goal-shared",
            tag: "same-first"
        )
        let secondRequest = try makeGoalRequest(
            sessionID: "goal-shared",
            tag: "same-second",
            previousResponseID: "resp_chatcmpl_goal_first"
        )
        let otherRequest = try makeGoalRequest(
            sessionID: "goal-other",
            tag: "other-session"
        )

        let firstTask = Task { () throws -> Int in
            let (_, response) = try await URLSession.shared.data(for: firstRequest)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        }
        let firstStarted = await waitUntil {
            await transport.hasStarted(tag: "same-first")
        }

        let secondTask = Task { () throws -> Int in
            let (_, response) = try await URLSession.shared.data(for: secondRequest)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        }
        let secondQueued = await waitUntil {
            await coordinator.queuedRequestCount(
                for: "header:session-id:goal-shared"
            ) == 1
        }

        let otherTask = Task { () throws -> Int in
            let (_, response) = try await URLSession.shared.data(for: otherRequest)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        }
        let otherStarted = await waitUntil {
            await transport.hasStarted(tag: "other-session")
        }
        let secondStartedBeforeFirstRelease = await transport.hasStarted(tag: "same-second")

        // Release every pending fixture path before awaiting task values, so
        // failures in an assertion cannot leave an HTTP request blocked.
        await transport.release(tag: "other-session")
        let otherStatus = try await otherTask.value
        await transport.release(tag: "same-first")
        let secondStartedAfterFirstRelease = await waitUntil {
            await transport.hasStarted(tag: "same-second")
        }
        await transport.release(tag: "same-second")

        let firstStatus = try await firstTask.value
        let secondStatus = try await secondTask.value
        let slotsCleanedUp = await waitUntil {
            await coordinator.trackedSessionCount() == 0
        }
        let convertedGoalToolNames = await transport.toolNames(for: "same-first")

        XCTAssertTrue(firstStarted, "The first same-session request should reach fake transport.")
        XCTAssertTrue(secondQueued, "The second same-session request should wait in its slot.")
        XCTAssertTrue(otherStarted, "A different session should reach fake transport concurrently.")
        XCTAssertFalse(
            secondStartedBeforeFirstRelease,
            "The second same-session request must not race the first upstream turn."
        )
        XCTAssertTrue(secondStartedAfterFirstRelease)
        XCTAssertTrue(slotsCleanedUp, "Completed session slots should be discarded.")
        XCTAssertEqual(convertedGoalToolNames, ["get_goal"])
        XCTAssertEqual([firstStatus, secondStatus, otherStatus], [200, 200, 200])
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

    func testFlattensResponsesNamespaceWrapperForOrdinaryRequests() throws {
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "input": [["role": "user", "content": "hello"]],
            "tools": [[
                "type": "namespace",
                "name": "mcp__browser",
                "description": "Browser tools",
                "tools": [[
                    "type": "function",
                    "name": "navigate",
                    "description": "Navigate to a URL",
                    "parameters": ["type": "object", "properties": [String: Any]()]
                ], [
                    "type": "custom",
                    "name": "evaluate",
                    "description": "Evaluate browser code"
                ]]
            ], [
                "type": "web_search"
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let tools = try XCTUnwrap(chat["tools"] as? [[String: Any]])
        let mappings = conversion.toolContext.mappings

        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(mappings.count, 2)
        XCTAssertEqual(Set(mappings.compactMap(\.namespace)), Set(["mcp__browser"]))
        XCTAssertEqual(Set(mappings.map(\.responseName)), Set(["navigate", "evaluate"]))
        XCTAssertEqual(
            Set(mappings.map(\.chatName)),
            Set(["mcp__browser__navigate", "mcp__browser__evaluate"])
        )
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

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
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

private actor BlockingBridgeTransport: OpenCodeGoBridgeTransport {
    private let responses: [String: OpenCodeGoBridgeTransportResponse]
    private let fallbackResponse = OpenCodeGoBridgeTransportResponse(
        statusCode: 500,
        headers: ["content-type": "application/json"],
        body: Data()
    )
    private var startedTags: Set<String> = []
    private var toolNamesByTag: [String: [String]] = [:]
    private var waitingContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var releasedTags: Set<String> = []

    init(responses: [String: OpenCodeGoBridgeTransportResponse]) {
        self.responses = responses
    }

    func execute(_ request: URLRequest) async throws -> OpenCodeGoBridgeTransportResponse {
        let details = Self.requestDetails(from: request)
        startedTags.insert(details.tag)
        toolNamesByTag[details.tag] = details.toolNames
        await wait(for: details.tag)
        return responses[details.tag] ?? fallbackResponse
    }

    func hasStarted(tag: String) -> Bool {
        startedTags.contains(tag)
    }

    func toolNames(for tag: String) -> [String] {
        toolNamesByTag[tag] ?? []
    }

    func release(tag: String) {
        if let continuation = waitingContinuations.removeValue(forKey: tag) {
            continuation.resume()
        } else {
            releasedTags.insert(tag)
        }
    }

    private func wait(for tag: String) async {
        guard releasedTags.remove(tag) == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            if releasedTags.remove(tag) != nil {
                continuation.resume()
            } else {
                waitingContinuations[tag] = continuation
            }
        }
    }

    private static func requestDetails(
        from request: URLRequest
    ) -> (tag: String, toolNames: [String]) {
        guard
            let body = request.httpBody,
            let object = try? JSONSerialization.jsonObject(with: body),
            let root = object as? [String: Any]
        else {
            return ("unknown", [])
        }
        let tag = (root["messages"] as? [[String: Any]])?
            .reversed()
            .compactMap { message -> String? in
                guard message["role"] as? String == "user" else {
                    return nil
                }
                return message["content"] as? String
            }
            .first ?? "unknown"
        let toolNames = (root["tools"] as? [[String: Any]])?.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        } ?? []
        return (tag, toolNames)
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
