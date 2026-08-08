import CryptoKit
import Darwin
import Foundation

/// A completed configuration switch that can be reverted if the file remains unchanged.
public struct SwitchReceipt: Codable, Hashable, Sendable {
    public let backupURL: URL
    public let beforeHash: String
    public let afterHash: String
    public let timestamp: Date
    public let originalConfigExisted: Bool
    public let catalogURL: URL?
    public let catalogBackupURL: URL?
    public let catalogBeforeHash: String?
    public let catalogAfterHash: String?
    public let originalCatalogExisted: Bool
    /// Whether the transaction's resulting catalog existed. Older apply
    /// receipts always created one, so missing legacy data decodes as `true`.
    public let catalogAfterExisted: Bool

    public init(
        backupURL: URL,
        beforeHash: String,
        afterHash: String,
        timestamp: Date,
        originalConfigExisted: Bool,
        catalogURL: URL? = nil,
        catalogBackupURL: URL? = nil,
        catalogBeforeHash: String? = nil,
        catalogAfterHash: String? = nil,
        originalCatalogExisted: Bool = false,
        catalogAfterExisted: Bool = true
    ) {
        self.backupURL = backupURL
        self.beforeHash = beforeHash
        self.afterHash = afterHash
        self.timestamp = timestamp
        self.originalConfigExisted = originalConfigExisted
        self.catalogURL = catalogURL
        self.catalogBackupURL = catalogBackupURL
        self.catalogBeforeHash = catalogBeforeHash
        self.catalogAfterHash = catalogAfterHash
        self.originalCatalogExisted = originalCatalogExisted
        self.catalogAfterExisted = catalogAfterExisted
    }

    private enum CodingKeys: String, CodingKey {
        case backupURL
        case beforeHash
        case afterHash
        case timestamp
        case originalConfigExisted
        case catalogURL
        case catalogBackupURL
        case catalogBeforeHash
        case catalogAfterHash
        case originalCatalogExisted
        case catalogAfterExisted
    }

    /// Older receipts only recorded `config.toml`. Decode their missing catalog
    /// fields as an intentional configuration-only transaction.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backupURL = try container.decode(URL.self, forKey: .backupURL)
        beforeHash = try container.decode(String.self, forKey: .beforeHash)
        afterHash = try container.decode(String.self, forKey: .afterHash)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        originalConfigExisted = try container.decode(Bool.self, forKey: .originalConfigExisted)
        catalogURL = try container.decodeIfPresent(URL.self, forKey: .catalogURL)
        catalogBackupURL = try container.decodeIfPresent(URL.self, forKey: .catalogBackupURL)
        catalogBeforeHash = try container.decodeIfPresent(String.self, forKey: .catalogBeforeHash)
        catalogAfterHash = try container.decodeIfPresent(String.self, forKey: .catalogAfterHash)
        originalCatalogExisted = try container.decodeIfPresent(
            Bool.self,
            forKey: .originalCatalogExisted
        ) ?? false
        catalogAfterExisted = try container.decodeIfPresent(
            Bool.self,
            forKey: .catalogAfterExisted
        ) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backupURL, forKey: .backupURL)
        try container.encode(beforeHash, forKey: .beforeHash)
        try container.encode(afterHash, forKey: .afterHash)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(originalConfigExisted, forKey: .originalConfigExisted)
        try container.encodeIfPresent(catalogURL, forKey: .catalogURL)
        try container.encodeIfPresent(catalogBackupURL, forKey: .catalogBackupURL)
        try container.encodeIfPresent(catalogBeforeHash, forKey: .catalogBeforeHash)
        try container.encodeIfPresent(catalogAfterHash, forKey: .catalogAfterHash)
        try container.encode(originalCatalogExisted, forKey: .originalCatalogExisted)
        try container.encode(catalogAfterExisted, forKey: .catalogAfterExisted)
    }
}

/// UI-facing operations supported by a client integration.
public protocol ClientAdapter {
    var bridgeStatus: OpenCodeGoBridgeStatus { get }
    func prepareForUse() throws
    func preview(profile: ProviderProfile) throws -> SwitchPreview
    func apply(profile: ProviderProfile) throws -> SwitchReceipt
    func undo(_ receipt: SwitchReceipt) throws
}

/// Adapters without a local service have no launch preparation to perform.
public extension ClientAdapter {
    var bridgeStatus: OpenCodeGoBridgeStatus {
        .stopped
    }

    func prepareForUse() throws {}
}

/// Codex-specific implementation that projects and atomically switches `~/.codex/config.toml`.
public struct CodexClientAdapter: ClientAdapter {
    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    public static var defaultCatalogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent(CodexModelCatalog.filename, isDirectory: false)
    }

    public let configURL: URL
    private let credentialStore: any CredentialStoring
    private let projector: CodexConfigProjector
    private let bridgeManager: any OpenCodeGoBridgeManaging
    private let atomicWriteInterceptor: (any CodexAtomicWriteIntercepting)?

    public var bridgeStatus: OpenCodeGoBridgeStatus {
        bridgeManager.status
    }

    public init(
        configURL: URL = CodexClientAdapter.defaultConfigURL,
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        projector: CodexConfigProjector = CodexConfigProjector(),
        bridgeManager: any OpenCodeGoBridgeManaging = OpenCodeGoBridgeManager.shared
    ) {
        self.init(
            configURL: configURL,
            credentialStore: credentialStore,
            projector: projector,
            bridgeManager: bridgeManager,
            atomicWriteInterceptor: nil
        )
    }

    /// Internal test seam for proving paired config/catalog rollback behavior.
    init(
        configURL: URL,
        credentialStore: any CredentialStoring,
        projector: CodexConfigProjector,
        bridgeManager: any OpenCodeGoBridgeManaging,
        atomicWriteInterceptor: (any CodexAtomicWriteIntercepting)?
    ) {
        self.configURL = configURL
        self.credentialStore = credentialStore
        self.projector = projector
        self.bridgeManager = bridgeManager
        self.atomicWriteInterceptor = atomicWriteInterceptor
    }

    public var catalogURL: URL {
        configURL
            .deletingLastPathComponent()
            .appendingPathComponent(CodexModelCatalog.filename, isDirectory: false)
    }

    /// Returns metadata for app-created `config.toml` backups only, newest
    /// first. No configuration, credential, session, or history contents are
    /// included in the returned inventory.
    public func listConfigurationBackups() throws -> [CodexConfigurationBackup] {
        try CodexBackupStore.listConfigurationBackups(for: configURL)
    }

    /// Restores a selected app-created configuration backup and returns a
    /// receipt that can be passed to `undo(_:)` to restore the prior state.
    ///
    /// Restore is intentionally limited to `config.toml` and this app's fixed
    /// model catalog path. It never changes `auth.json`, Keychain credentials,
    /// session JSONL, history, or Codex state databases.
    public func restoreConfigurationBackup(
        _ backup: CodexConfigurationBackup
    ) throws -> SwitchReceipt {
        try restoreConfigurationBackup(at: backup.url)
    }

    /// Convenience overload for callers that retain only a selected backup URL.
    public func restoreConfigurationBackup(_ backupURL: URL) throws -> SwitchReceipt {
        try restoreConfigurationBackup(at: backupURL)
    }

    /// Restores one selected app-created configuration backup after strict
    /// path, size, UTF-8, and structural TOML checks.
    public func restoreConfigurationBackup(at backupURL: URL) throws -> SwitchReceipt {
        let restoredConfigurationData = try CodexBackupStore.configurationData(
            from: backupURL,
            for: configURL
        )
        guard let restoredConfiguration = String(
            data: restoredConfigurationData,
            encoding: .utf8
        ) else {
            throw CodexSwitchError.invalidConfigurationBackup
        }

        let configurationSnapshot = try readConfiguration()
        let ownedCatalogURL = try ownedCatalogURL()
        let catalogSnapshot = try readCatalogSnapshot(
            at: ownedCatalogURL,
            validateSchema: false
        )
        let restoredCatalog: FileSnapshot
        if try Self.hasAppOwnedCatalogPointer(in: restoredConfiguration) {
            restoredCatalog = FileSnapshot(
                data: try CodexBackupStore.catalogDataMatchingConfigurationBackup(
                    backupURL,
                    for: configURL
                ),
                existed: true
            )
        } else {
            // A restored external (or absent) pointer must never cause us to
            // modify that external catalog. Only the fixed app-owned file is
            // removed as part of this transaction.
            restoredCatalog = FileSnapshot(data: Data(), existed: false)
        }

        let timestamp = Date()
        let safetyBackupURL = try createBackup(
            for: configurationSnapshot.data,
            sourceURL: configURL,
            timestamp: timestamp
        )
        let catalogSafetyBackupURL = try createBackup(
            for: catalogSnapshot.data,
            sourceURL: ownedCatalogURL,
            timestamp: timestamp
        )

        // Do not overwrite a configuration or catalog changed after its
        // safety snapshot was taken.
        let currentConfiguration = try readConfiguration()
        guard snapshotsMatch(
            currentConfiguration.fileSnapshot,
            configurationSnapshot.fileSnapshot
        ) else {
            throw CodexSwitchError.configurationChanged
        }
        let currentCatalog = try readCatalogSnapshot(
            at: ownedCatalogURL,
            validateSchema: false
        )
        guard snapshotsMatch(currentCatalog, catalogSnapshot) else {
            throw CodexSwitchError.modelCatalogChanged
        }

        try writeTransaction(
            catalog: restoredCatalog,
            configuration: FileSnapshot(
                data: restoredConfigurationData,
                existed: true
            ),
            originalCatalog: catalogSnapshot,
            originalConfiguration: configurationSnapshot.fileSnapshot,
            catalogURL: ownedCatalogURL
        )

        return SwitchReceipt(
            backupURL: safetyBackupURL,
            beforeHash: hash(configurationSnapshot.data),
            afterHash: hash(restoredConfigurationData),
            timestamp: timestamp,
            originalConfigExisted: configurationSnapshot.existed,
            catalogURL: ownedCatalogURL,
            catalogBackupURL: catalogSafetyBackupURL,
            catalogBeforeHash: hash(catalogSnapshot.data),
            catalogAfterHash: hash(restoredCatalog.data),
            originalCatalogExisted: catalogSnapshot.existed,
            catalogAfterExisted: restoredCatalog.existed
        )
    }

    /// Alias for clients that present configuration backups generically.
    public func restoreBackup(at backupURL: URL) throws -> SwitchReceipt {
        try restoreConfigurationBackup(at: backupURL)
    }

    /// Starts the loopback bridge only when the active existing configuration
    /// points Codex at the legacy bridge provider or contains this app's
    /// session-preservation markers. A preservation configuration is rebuilt
    /// from non-secret TOML comments and retrieves its credential afresh from
    /// Keychain on each app launch.
    public func prepareForUse() throws {
        let snapshot = try readConfiguration()
        if let preservedConfiguration = Self.preservedSessionBridgeConfiguration(
            in: snapshot.text
        ) {
            let credential = try credential(for: preservedConfiguration.profileID)
            try configureBridgeForPreservingSessions(
                route: preservedConfiguration.route,
                credential: credential
            )
            try bridgeManager.ensureRunning()
            return
        }

        guard Self.activeModelProvider(in: snapshot.text) == ProviderCatalog.openCodeGoBridgeProviderID else {
            return
        }
        configureLegacyBridgeMode()
        try bridgeManager.ensureRunning()
    }

    public func preview(profile: ProviderProfile) throws -> SwitchPreview {
        let snapshot = try readConfiguration()
        let catalog = try CodexModelCatalog.make(for: profile)
        let projected = try projector.project(original: snapshot.text, profile: profile)
        let presetName = ProviderCatalog.preset(for: profile.presetID)?.displayName ?? "provider"

        return SwitchPreview(
            original: snapshot.text,
            projected: projected,
            summary: "Set Codex to \(presetName) with model \(profile.model) and advertise \(catalog.models.count) models."
        )
    }

    public func apply(profile: ProviderProfile) throws -> SwitchReceipt {
        let credential = try credential(for: profile.id)
        let route = try ProviderCatalog.route(for: profile)
        let configurationSnapshot = try readConfiguration()
        let catalog = try CodexModelCatalog.make(for: profile)
        let projected = try projector.project(
            original: configurationSnapshot.text,
            profile: profile
        )
        let ownedCatalogURL = try ownedCatalogURL()
        let catalogSnapshot = try readCatalogSnapshot(
            at: ownedCatalogURL,
            validateSchema: true
        )
        let catalogData = try catalog.encodedData()
        let projectedData = Data(projected.utf8)
        let timestamp = Date()
        let backupURL = try createBackup(
            for: configurationSnapshot.data,
            sourceURL: configURL,
            timestamp: timestamp
        )
        let catalogBackupURL = try createBackup(
            for: catalogSnapshot.data,
            sourceURL: ownedCatalogURL,
            timestamp: timestamp
        )

        if profile.preserveSessions {
            // The listener must be configured and available before Codex is
            // pointed at its fixed OpenAI base URL. The Keychain value stays
            // in bridge memory only; it is never rendered into TOML.
            try configureBridgeForPreservingSessions(route: route, credential: credential)
            try bridgeManager.ensureRunning()
        } else {
            // Clear any earlier session-preservation credential before a
            // normal custom-provider switch. No listener is started for
            // direct Responses routes, preserving the existing behavior.
            configureLegacyBridgeMode()
        }
        if !profile.preserveSessions, route.requiresLoopbackBridge {
            // The listener must be available before Codex is pointed at it.
            try bridgeManager.ensureRunning()
        }
        try writeTransaction(
            catalog: FileSnapshot(data: catalogData, existed: true),
            configuration: FileSnapshot(data: projectedData, existed: true),
            originalCatalog: catalogSnapshot,
            originalConfiguration: configurationSnapshot.fileSnapshot,
            catalogURL: ownedCatalogURL
        )

        return SwitchReceipt(
            backupURL: backupURL,
            beforeHash: hash(configurationSnapshot.data),
            afterHash: hash(projectedData),
            timestamp: timestamp,
            originalConfigExisted: configurationSnapshot.existed,
            catalogURL: ownedCatalogURL,
            catalogBackupURL: catalogBackupURL,
            catalogBeforeHash: hash(catalogSnapshot.data),
            catalogAfterHash: hash(catalogData),
            originalCatalogExisted: catalogSnapshot.existed
        )
    }

    public func undo(_ receipt: SwitchReceipt) throws {
        let currentConfiguration = try readConfiguration()
        guard
            currentConfiguration.existed,
            hash(currentConfiguration.data) == receipt.afterHash
        else {
            throw CodexSwitchError.configurationChanged
        }

        let configurationBackup = try readConfigurationBackup(at: receipt.backupURL)
        guard hash(configurationBackup) == receipt.beforeHash else {
            throw CodexSwitchError.backupIntegrityConflict
        }

        let originalConfiguration = FileSnapshot(
            data: configurationBackup,
            existed: receipt.originalConfigExisted
        )

        guard let catalogTransaction = try catalogTransaction(from: receipt) else {
            try restore(snapshot: originalConfiguration, to: configURL)
            return
        }

        let ownedCatalogURL = try ownedCatalogURL()
        guard
            catalogTransaction.catalogURL.standardizedFileURL
                == ownedCatalogURL.standardizedFileURL
        else {
            throw CodexModelCatalogError.unsafeCatalogPath
        }
        try CodexModelCatalog.validateOwnedCatalogURL(
            ownedCatalogURL,
            for: configURL
        )

        let currentCatalog = try readCatalogSnapshot(
            at: ownedCatalogURL,
            validateSchema: false
        )
        guard
            currentCatalog.existed == catalogTransaction.afterExisted,
            hash(currentCatalog.data) == catalogTransaction.afterHash
        else {
            throw CodexSwitchError.modelCatalogChanged
        }

        let catalogBackup = try readCatalogBackup(at: catalogTransaction.backupURL)
        guard hash(catalogBackup) == catalogTransaction.beforeHash else {
            throw CodexSwitchError.backupIntegrityConflict
        }

        let originalCatalog = FileSnapshot(
            data: catalogBackup,
            existed: catalogTransaction.originalExisted
        )
        try restoreTransaction(
            catalog: originalCatalog,
            configuration: originalConfiguration,
            currentCatalog: currentCatalog,
            currentConfiguration: currentConfiguration.fileSnapshot,
            catalogURL: ownedCatalogURL
        )
    }

    private func credential(for profileID: UUID) throws -> Data {
        do {
            let credential = try credentialStore.read(for: profileID)
            guard !credential.isEmpty else {
                throw CodexSwitchError.missingCredential
            }
            return credential
        } catch is CodexSwitchError {
            throw CodexSwitchError.missingCredential
        } catch {
            throw CodexSwitchError.missingCredential
        }
    }

    private func configureLegacyBridgeMode() {
        (bridgeManager as? any OpenCodeGoBridgeConfiguring)?
            .configureLegacyChatMode()
    }

    private func configureBridgeForPreservingSessions(
        route: ProviderRoute,
        credential: Data
    ) throws {
        guard let bridge = bridgeManager as? any OpenCodeGoBridgeConfiguring else {
            // A preserve projection without a credential-injecting bridge
            // would direct Codex at loopback and silently break requests.
            throw OpenCodeGoBridgeError.unableToStart
        }
        bridge.configurePreservingSessions(route: route, credential: credential)
    }

    private func readConfiguration() throws -> ConfigurationSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configURL.path) else {
            return ConfigurationSnapshot(text: "", data: Data(), existed: false)
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw CodexSwitchError.unreadableConfiguration
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexSwitchError.unreadableConfiguration
        }
        return ConfigurationSnapshot(text: text, data: data, existed: true)
    }

    private func ownedCatalogURL() throws -> URL {
        let url = try CodexModelCatalog.catalogURL(for: configURL)
        try CodexModelCatalog.validateOwnedCatalogURL(url, for: configURL)
        return url
    }

    private func readCatalogSnapshot(
        at url: URL,
        validateSchema: Bool
    ) throws -> FileSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return FileSnapshot(data: Data(), existed: false)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexModelCatalogError.unreadableCatalog
        }
        guard data.count <= CodexModelCatalog.maximumCatalogBytes else {
            throw CodexModelCatalogError.catalogTooLarge
        }
        if validateSchema {
            _ = try CodexModelCatalog.decodeValidated(from: data)
        }
        return FileSnapshot(data: data, existed: true)
    }

    private func readConfigurationBackup(at url: URL) throws -> Data {
        // Undo accepts legacy text backups, but still constrains the receipt
        // path to our backup directory and rejects non-UTF-8 content.
        try CodexBackupStore.configurationData(
            from: url,
            for: configURL,
            validateTOML: false
        )
    }

    private func readCatalogBackup(at url: URL) throws -> Data {
        try CodexBackupStore.backupData(
            from: url,
            for: configURL,
            sourceFilename: CodexModelCatalog.filename,
            maximumBytes: CodexModelCatalog.maximumCatalogBytes
        )
    }

    private func catalogTransaction(
        from receipt: SwitchReceipt
    ) throws -> CatalogTransaction? {
        let fieldPresence = [
            receipt.catalogURL != nil,
            receipt.catalogBackupURL != nil,
            receipt.catalogBeforeHash != nil,
            receipt.catalogAfterHash != nil
        ]

        guard fieldPresence.contains(true) else {
            guard !receipt.originalCatalogExisted else {
                throw CodexSwitchError.backupIntegrityConflict
            }
            return nil
        }
        guard fieldPresence.allSatisfy({ $0 }) else {
            throw CodexSwitchError.backupIntegrityConflict
        }
        guard
            let catalogURL = receipt.catalogURL,
            let backupURL = receipt.catalogBackupURL,
            let beforeHash = receipt.catalogBeforeHash,
            let afterHash = receipt.catalogAfterHash
        else {
            throw CodexSwitchError.backupIntegrityConflict
        }

        return CatalogTransaction(
            catalogURL: catalogURL,
            backupURL: backupURL,
            beforeHash: beforeHash,
            afterHash: afterHash,
            originalExisted: receipt.originalCatalogExisted,
            afterExisted: receipt.catalogAfterExisted
        )
    }

    private func createBackup(
        for data: Data,
        sourceURL: URL,
        timestamp: Date
    ) throws -> URL {
        let directoryURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)

        try ensurePrivateDirectory(directoryURL)

        let timestampComponent = CodexBackupStore.timestampComponent(for: timestamp)
        var candidate = directoryURL.appendingPathComponent(
            "\(sourceURL.lastPathComponent).backup-\(timestampComponent)"
        )
        var collisionIndex = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent(
                "\(sourceURL.lastPathComponent).backup-\(timestampComponent)-\(collisionIndex)"
            )
            collisionIndex += 1
        }

        try atomicallyWrite(data, to: candidate)
        return candidate
    }

    private func writeTransaction(
        catalog: FileSnapshot,
        configuration: FileSnapshot,
        originalCatalog: FileSnapshot,
        originalConfiguration: FileSnapshot,
        catalogURL: URL
    ) throws {
        do {
            try restore(snapshot: catalog, to: catalogURL)
            try restore(snapshot: configuration, to: configURL)
        } catch {
            guard rollback(
                configuration: originalConfiguration,
                catalog: originalCatalog,
                catalogURL: catalogURL
            ) else {
                throw CodexSwitchError.unableToWriteConfiguration
            }
            throw error
        }
    }

    private func restoreTransaction(
        catalog: FileSnapshot,
        configuration: FileSnapshot,
        currentCatalog: FileSnapshot,
        currentConfiguration: FileSnapshot,
        catalogURL: URL
    ) throws {
        do {
            try restore(snapshot: catalog, to: catalogURL)
            try restore(snapshot: configuration, to: configURL)
        } catch {
            guard rollback(
                configuration: currentConfiguration,
                catalog: currentCatalog,
                catalogURL: catalogURL
            ) else {
                throw CodexSwitchError.unableToWriteConfiguration
            }
            throw error
        }
    }

    /// Attempts both rollbacks even when the first one fails, so a partial
    /// config/catalog transaction has the best chance of returning to its
    /// original pair before reporting a write failure.
    private func rollback(
        configuration: FileSnapshot,
        catalog: FileSnapshot,
        catalogURL: URL
    ) -> Bool {
        var succeeded = true
        do {
            try restore(snapshot: configuration, to: configURL)
        } catch {
            succeeded = false
        }
        do {
            try restore(snapshot: catalog, to: catalogURL)
        } catch {
            succeeded = false
        }
        return succeeded
    }

    private func restore(snapshot: FileSnapshot, to destination: URL) throws {
        if snapshot.existed {
            try atomicallyWrite(snapshot.data, to: destination)
            return
        }

        guard FileManager.default.fileExists(atPath: destination.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            throw CodexSwitchError.unableToWriteConfiguration
        }
    }

    private func ensurePrivateDirectory(_ directoryURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CodexSwitchError.unableToWriteConfiguration
        }

        guard directoryURL.path.withCString({ Darwin.chmod($0, mode_t(0o700)) }) == 0 else {
            throw CodexSwitchError.unableToWriteConfiguration
        }
    }

    private func atomicallyWrite(_ data: Data, to destination: URL) throws {
        let directoryURL = destination.deletingLastPathComponent()
        try ensurePrivateDirectory(directoryURL)
        do {
            try atomicWriteInterceptor?.willWriteAtomically(to: destination)
        } catch {
            throw CodexSwitchError.unableToWriteConfiguration
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let fileDescriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard fileDescriptor >= 0 else {
            throw CodexSwitchError.unableToWriteConfiguration
        }

        var descriptor = fileDescriptor
        var shouldRemoveTemporaryFile = true
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            if shouldRemoveTemporaryFile {
                _ = temporaryURL.path.withCString { Darwin.unlink($0) }
            }
        }

        guard writeAll(data, to: descriptor), Darwin.fsync(descriptor) == 0 else {
            throw CodexSwitchError.unableToWriteConfiguration
        }
        guard Darwin.close(descriptor) == 0 else {
            throw CodexSwitchError.unableToWriteConfiguration
        }
        descriptor = -1

        let renameSucceeded = temporaryURL.path.withCString { temporaryPath in
            destination.path.withCString { destinationPath in
                Darwin.rename(temporaryPath, destinationPath) == 0
            }
        }
        guard renameSucceeded else {
            throw CodexSwitchError.unableToWriteConfiguration
        }
        shouldRemoveTemporaryFile = false

        guard destination.path.withCString({ Darwin.chmod($0, mode_t(0o600)) }) == 0 else {
            throw CodexSwitchError.unableToWriteConfiguration
        }
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else {
                return true
            }

            var remainingByteCount = rawBuffer.count
            while remainingByteCount > 0 {
                let writtenByteCount = Darwin.write(fileDescriptor, pointer, remainingByteCount)
                if writtenByteCount > 0 {
                    pointer = pointer.advanced(by: writtenByteCount)
                    remainingByteCount -= writtenByteCount
                    continue
                }
                if writtenByteCount == -1, errno == EINTR {
                    continue
                }
                return false
            }
            return true
        }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func snapshotsMatch(_ lhs: FileSnapshot, _ rhs: FileSnapshot) -> Bool {
        lhs.existed == rhs.existed && hash(lhs.data) == hash(rhs.data)
    }

    /// Identifies only the pointer shape emitted by this application's managed
    /// active block. A bare or malformed fixed-name pointer is rejected rather
    /// than guessed, preventing an incomplete backup from pairing with the
    /// wrong catalog.
    private static func hasAppOwnedCatalogPointer(in configuration: String) throws -> Bool {
        var activeBeginIndices: [Int] = []
        var activeEndIndices: [Int] = []
        var catalogMarkerIndices: [Int] = []
        var catalogPointers: [(index: Int, value: String?)] = []
        var multilineDelimiter: String?

        for (index, rawLine) in configuration
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            var line = String(rawLine)
            if line.last == "\r" {
                line.removeLast()
            }

            if let activeDelimiter = multilineDelimiter {
                if line.contains(activeDelimiter) {
                    multilineDelimiter = nil
                }
                continue
            }
            if let delimiter = multilineDelimiterOpened(in: line) {
                multilineDelimiter = delimiter
                continue
            }

            switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
            case CodexConfigProjector.activeBeginMarker:
                activeBeginIndices.append(index)
                continue
            case CodexConfigProjector.activeEndMarker:
                activeEndIndices.append(index)
                continue
            case CodexConfigProjector.catalogPointerMarker:
                catalogMarkerIndices.append(index)
                continue
            default:
                break
            }

            let code = codeBeforeComment(in: line)
                .trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else {
                continue
            }
            if isTomlTableHeader(code) {
                break
            }

            guard let equalsIndex = code.firstIndex(of: "=") else {
                continue
            }
            let rawKey = code[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard key == "model_catalog_json" else {
                continue
            }
            let rawValue = code[code.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespaces)
            catalogPointers.append((
                index: index,
                value: tomlStringValue(rawValue)
            ))
        }

        guard
            activeBeginIndices.count == activeEndIndices.count,
            activeBeginIndices.count <= 1,
            catalogMarkerIndices.count <= 1,
            catalogPointers.count <= 1
        else {
            throw CodexSwitchError.invalidConfigurationBackup
        }
        guard
            let pointer = catalogPointers.first,
            pointer.value == CodexModelCatalog.filename
        else {
            return false
        }
        guard
            let activeBegin = activeBeginIndices.first,
            let activeEnd = activeEndIndices.first,
            let catalogMarker = catalogMarkerIndices.first,
            activeBegin < activeEnd,
            (activeBegin...activeEnd).contains(catalogMarker),
            (activeBegin...activeEnd).contains(pointer.index)
        else {
            throw CodexSwitchError.invalidConfigurationBackup
        }
        return true
    }

    private static func activeModelProvider(in configuration: String) -> String? {
        var multilineDelimiter: String?

        for rawLine in configuration.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.last == "\r" {
                line.removeLast()
            }

            if let activeDelimiter = multilineDelimiter {
                if line.contains(activeDelimiter) {
                    multilineDelimiter = nil
                }
                continue
            }

            if let delimiter = multilineDelimiterOpened(in: line) {
                multilineDelimiter = delimiter
                continue
            }

            let code = codeBeforeComment(in: line)
                .trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else {
                continue
            }
            if isTomlTableHeader(code) {
                break
            }
            guard let equalsIndex = code.firstIndex(of: "=") else {
                continue
            }

            let rawKey = code[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard key == "model_provider" else {
                continue
            }

            let rawValue = code[code.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespaces)
            return tomlStringValue(rawValue)
        }
        return nil
    }

    /// Reconstructs only the exact non-secret preservation marker shape
    /// emitted by `CodexConfigProjector`. Invalid or user-authored marker
    /// fragments are ignored rather than guessed, so launch preparation never
    /// sends a Keychain credential to an unverified route.
    private static func preservedSessionBridgeConfiguration(
        in configuration: String
    ) -> PreservedSessionBridgeConfiguration? {
        let lines = configuration
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                var line = String(rawLine)
                if line.last == "\r" {
                    line.removeLast()
                }
                return line
            }

        var activeBeginIndices: [Int] = []
        var activeEndIndices: [Int] = []
        var firstTableIndex: Int?
        var multilineDelimiter: String?

        for index in lines.indices {
            let line = lines[index]
            if let activeDelimiter = multilineDelimiter {
                if line.contains(activeDelimiter) {
                    multilineDelimiter = nil
                }
                continue
            }
            if let delimiter = multilineDelimiterOpened(in: line) {
                multilineDelimiter = delimiter
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == CodexConfigProjector.activeBeginMarker {
                activeBeginIndices.append(index)
                continue
            }
            if trimmed == CodexConfigProjector.activeEndMarker {
                activeEndIndices.append(index)
                continue
            }
            if isTomlTableHeader(codeBeforeComment(in: line).trimmingCharacters(in: .whitespaces)) {
                firstTableIndex = firstTableIndex ?? index
            }
        }

        guard
            activeBeginIndices.count == 1,
            activeEndIndices.count == 1,
            let activeBegin = activeBeginIndices.first,
            let activeEnd = activeEndIndices.first,
            activeBegin < activeEnd,
            firstTableIndex.map({ activeEnd < $0 }) ?? true
        else {
            return nil
        }

        let activeLines = Array(lines[activeBegin...activeEnd])
        guard
            activeLines.count(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    == CodexConfigProjector.preserveSessionsMarker
            }) == 1,
            activeLines.count(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    == CodexConfigProjector.openAIBaseURLMarker
            }) == 1,
            let profileMarker = markerValue(
                withPrefix: CodexConfigProjector.preserveProfileIDMarkerPrefix,
                in: activeLines
            ),
            let profileID = UUID(uuidString: profileMarker),
            let presetMarker = markerValue(
                withPrefix: CodexConfigProjector.preservePresetMarkerPrefix,
                in: activeLines
            ),
            let presetID = ProviderPresetID(rawValue: presetMarker),
            let model = stringAssignment(named: "model", in: activeLines),
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            stringAssignment(named: "model_provider", in: activeLines) == nil,
            stringAssignment(named: "openai_base_url", in: activeLines)
                == ProviderCatalog.openCodeGoBridgeBaseURL
        else {
            return nil
        }

        let profile = ProviderProfile(
            id: profileID,
            name: "",
            presetID: presetID,
            model: model,
            preserveSessions: true,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        guard let route = try? ProviderCatalog.route(for: profile) else {
            return nil
        }
        return PreservedSessionBridgeConfiguration(profileID: profileID, route: route)
    }

    private static func markerValue(withPrefix prefix: String, in lines: [String]) -> String? {
        let values = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix) else {
                return nil
            }
            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard values.count == 1, let value = values.first, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func stringAssignment(named expectedKey: String, in lines: [String]) -> String? {
        var value: String?
        for line in lines {
            let code = codeBeforeComment(in: line).trimmingCharacters(in: .whitespaces)
            guard
                !code.isEmpty,
                let equalsIndex = code.firstIndex(of: "=")
            else {
                continue
            }
            let rawKey = code[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard key == expectedKey else {
                continue
            }
            guard value == nil else {
                return nil
            }
            let rawValue = code[code.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespaces)
            guard let decoded = tomlStringValue(rawValue) else {
                return nil
            }
            value = decoded
        }
        return value
    }

    private static func multilineDelimiterOpened(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard
            !trimmed.hasPrefix("#"),
            let equalsIndex = trimmed.firstIndex(of: "=")
        else {
            return nil
        }
        let value = trimmed[trimmed.index(after: equalsIndex)...]
            .trimmingCharacters(in: .whitespaces)
        for delimiter in ["\"\"\"", "'''"] {
            guard value.hasPrefix(delimiter) else {
                continue
            }
            let remainder = value.dropFirst(delimiter.count)
            return remainder.contains(delimiter) ? nil : delimiter
        }
        return nil
    }

    private static func codeBeforeComment(in line: String) -> String {
        var inBasicString = false
        var inLiteralString = false
        var isEscaped = false

        for index in line.indices {
            let character = line[index]
            if inBasicString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inBasicString = false
                }
                continue
            }
            if inLiteralString {
                if character == "'" {
                    inLiteralString = false
                }
                continue
            }

            switch character {
            case "\"":
                inBasicString = true
            case "'":
                inLiteralString = true
            case "#":
                return String(line[..<index])
            default:
                continue
            }
        }
        return line
    }

    private static func isTomlTableHeader(_ line: String) -> Bool {
        line.hasPrefix("[") && (line.hasSuffix("]") || line.hasSuffix("]]"))
    }

    private static func tomlStringValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let quote = trimmed.first,
              quote == "\"" || quote == "'",
              trimmed.last == quote
        else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
    }

}

private struct ConfigurationSnapshot {
    let text: String
    let data: Data
    let existed: Bool

    var fileSnapshot: FileSnapshot {
        FileSnapshot(data: data, existed: existed)
    }
}

private struct PreservedSessionBridgeConfiguration {
    let profileID: UUID
    let route: ProviderRoute
}

private struct FileSnapshot {
    let data: Data
    let existed: Bool
}

/// Test-only fault injector for verifying paired file transaction rollback.
protocol CodexAtomicWriteIntercepting: AnyObject {
    func willWriteAtomically(to destination: URL) throws
}

private struct CatalogTransaction {
    let catalogURL: URL
    let backupURL: URL
    let beforeHash: String
    let afterHash: String
    let originalExisted: Bool
    let afterExisted: Bool
}
