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
        originalCatalogExisted: Bool = false
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

    public var bridgeStatus: OpenCodeGoBridgeStatus {
        bridgeManager.status
    }

    public init(
        configURL: URL = CodexClientAdapter.defaultConfigURL,
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        projector: CodexConfigProjector = CodexConfigProjector(),
        bridgeManager: any OpenCodeGoBridgeManaging = OpenCodeGoBridgeManager.shared
    ) {
        self.configURL = configURL
        self.credentialStore = credentialStore
        self.projector = projector
        self.bridgeManager = bridgeManager
    }

    public var catalogURL: URL {
        configURL
            .deletingLastPathComponent()
            .appendingPathComponent(CodexModelCatalog.filename, isDirectory: false)
    }

    /// Starts the loopback bridge only when the active existing configuration
    /// points Codex at the bridge provider. This prevents an OpenRouter-only
    /// installation from claiming the bridge port during launch.
    public func prepareForUse() throws {
        let snapshot = try readConfiguration()
        guard Self.activeModelProvider(in: snapshot.text) == ProviderCatalog.openCodeGoBridgeProviderID else {
            return
        }
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
        try requireCredential(for: profile.id)
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

        if route.requiresLoopbackBridge {
            // The listener must be available before Codex is pointed at it.
            try bridgeManager.ensureRunning()
        }
        try writeTransaction(
            catalogData: catalogData,
            configurationData: projectedData,
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

        let configurationBackup = try readBackup(at: receipt.backupURL)
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
            currentCatalog.existed,
            hash(currentCatalog.data) == catalogTransaction.afterHash
        else {
            throw CodexSwitchError.modelCatalogChanged
        }

        let catalogBackup = try readBackup(at: catalogTransaction.backupURL)
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

    private func requireCredential(for profileID: UUID) throws {
        do {
            let credential = try credentialStore.read(for: profileID)
            guard !credential.isEmpty else {
                throw CodexSwitchError.missingCredential
            }
        } catch is CodexSwitchError {
            throw CodexSwitchError.missingCredential
        } catch {
            throw CodexSwitchError.missingCredential
        }
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

    private func readBackup(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CodexSwitchError.backupUnavailable
        }
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
            originalExisted: receipt.originalCatalogExisted
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

        let timestampComponent = Self.backupTimestampFormatter.string(from: timestamp)
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
        catalogData: Data,
        configurationData: Data,
        originalCatalog: FileSnapshot,
        originalConfiguration: FileSnapshot,
        catalogURL: URL
    ) throws {
        do {
            try atomicallyWrite(catalogData, to: catalogURL)
            try atomicallyWrite(configurationData, to: configURL)
        } catch {
            do {
                try restore(snapshot: originalConfiguration, to: configURL)
                try restore(snapshot: originalCatalog, to: catalogURL)
            } catch {
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
            do {
                try restore(snapshot: currentCatalog, to: catalogURL)
                try restore(snapshot: currentConfiguration, to: configURL)
            } catch {
                throw CodexSwitchError.unableToWriteConfiguration
            }
            throw error
        }
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

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter
    }()
}

private struct ConfigurationSnapshot {
    let text: String
    let data: Data
    let existed: Bool

    var fileSnapshot: FileSnapshot {
        FileSnapshot(data: data, existed: existed)
    }
}

private struct FileSnapshot {
    let data: Data
    let existed: Bool
}

private struct CatalogTransaction {
    let catalogURL: URL
    let backupURL: URL
    let beforeHash: String
    let afterHash: String
    let originalExisted: Bool
}
