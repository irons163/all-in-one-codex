import Foundation
import XCTest

@testable import AllInOneCodex

final class CodexCoreTests: XCTestCase {
    func testProviderCatalogContainsRequiredPresets() throws {
        let openCodeGo = try XCTUnwrap(ProviderCatalog.preset(for: .openCodeGo))
        XCTAssertEqual(openCodeGo.baseURL, "https://opencode.ai/zen/go/v1")
        XCTAssertEqual(openCodeGo.defaultModel, "gpt-5.6-luna")
        XCTAssertEqual(openCodeGo.providerID, "all_in_one_opencode_go")

        let openRouter = try XCTUnwrap(ProviderCatalog.preset(for: .openRouter))
        XCTAssertEqual(openRouter.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(openRouter.defaultModel, "openai/gpt-5.3-codex")
        XCTAssertEqual(openRouter.providerID, "all_in_one_openrouter")
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

        let adapter = CodexClientAdapter(configURL: configURL, credentialStore: credentials)
        let preview = try adapter.preview(profile: profile)
        XCTAssertFalse(preview.projected.contains(keyMaterial))

        _ = try adapter.apply(profile: profile)
        let appliedConfiguration = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(appliedConfiguration.contains(keyMaterial))
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
        XCTAssertNotEqual(try String(contentsOf: configURL, encoding: .utf8), original)

        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o777, 0o600)

        try adapter.undo(receipt)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)

        let secondReceipt = try adapter.apply(profile: profile)
        try Data("# External edit\n".utf8).write(to: configURL)
        XCTAssertThrowsError(try adapter.undo(secondReceipt)) { error in
            XCTAssertEqual(error as? CodexSwitchError, .configurationChanged)
        }
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

    private func makeProfile(presetID: ProviderPresetID) -> ProviderProfile {
        ProviderProfile(
            name: "Test profile",
            presetID: presetID,
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
