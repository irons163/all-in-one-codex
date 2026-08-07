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

    public init(
        backupURL: URL,
        beforeHash: String,
        afterHash: String,
        timestamp: Date,
        originalConfigExisted: Bool
    ) {
        self.backupURL = backupURL
        self.beforeHash = beforeHash
        self.afterHash = afterHash
        self.timestamp = timestamp
        self.originalConfigExisted = originalConfigExisted
    }
}

/// UI-facing operations supported by a client integration.
public protocol ClientAdapter {
    func preview(profile: ProviderProfile) throws -> SwitchPreview
    func apply(profile: ProviderProfile) throws -> SwitchReceipt
    func undo(_ receipt: SwitchReceipt) throws
}

/// Codex-specific implementation that projects and atomically switches `~/.codex/config.toml`.
public struct CodexClientAdapter: ClientAdapter {
    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    public let configURL: URL
    private let credentialStore: any CredentialStoring
    private let projector: CodexConfigProjector

    public init(
        configURL: URL = CodexClientAdapter.defaultConfigURL,
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        projector: CodexConfigProjector = CodexConfigProjector()
    ) {
        self.configURL = configURL
        self.credentialStore = credentialStore
        self.projector = projector
    }

    public func preview(profile: ProviderProfile) throws -> SwitchPreview {
        let snapshot = try readConfiguration()
        let projected = try projector.project(original: snapshot.text, profile: profile)
        let presetName = ProviderCatalog.preset(for: profile.presetID)?.displayName ?? "provider"

        return SwitchPreview(
            original: snapshot.text,
            projected: projected,
            summary: "Set Codex to \(presetName) with model \(profile.model)."
        )
    }

    public func apply(profile: ProviderProfile) throws -> SwitchReceipt {
        try requireCredential(for: profile.id)

        let snapshot = try readConfiguration()
        let projected = try projector.project(original: snapshot.text, profile: profile)
        let timestamp = Date()
        let backupURL = try createBackup(for: snapshot.data, timestamp: timestamp)
        let projectedData = Data(projected.utf8)

        try atomicallyWrite(projectedData, to: configURL)

        return SwitchReceipt(
            backupURL: backupURL,
            beforeHash: hash(snapshot.data),
            afterHash: hash(projectedData),
            timestamp: timestamp,
            originalConfigExisted: snapshot.existed
        )
    }

    public func undo(_ receipt: SwitchReceipt) throws {
        let current = try readConfiguration()
        guard current.existed, hash(current.data) == receipt.afterHash else {
            throw CodexSwitchError.configurationChanged
        }

        let backupData: Data
        do {
            backupData = try Data(contentsOf: receipt.backupURL)
        } catch {
            throw CodexSwitchError.backupUnavailable
        }

        guard hash(backupData) == receipt.beforeHash else {
            throw CodexSwitchError.backupIntegrityConflict
        }

        if receipt.originalConfigExisted {
            try atomicallyWrite(backupData, to: configURL)
        } else {
            do {
                try FileManager.default.removeItem(at: configURL)
            } catch {
                throw CodexSwitchError.unableToWriteConfiguration
            }
        }
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

    private func createBackup(for data: Data, timestamp: Date) throws -> URL {
        let directoryURL = configURL
            .deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CodexSwitchError.unableToWriteConfiguration
        }

        let timestampComponent = Self.backupTimestampFormatter.string(from: timestamp)
        var candidate = directoryURL.appendingPathComponent(
            "\(configURL.lastPathComponent).backup-\(timestampComponent)"
        )
        var collisionIndex = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent(
                "\(configURL.lastPathComponent).backup-\(timestampComponent)-\(collisionIndex)"
            )
            collisionIndex += 1
        }

        try atomicallyWrite(data, to: candidate)
        return candidate
    }

    private func atomicallyWrite(_ data: Data, to destination: URL) throws {
        let directoryURL = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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
}
