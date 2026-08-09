import Darwin
import Foundation

/// One non-secret, undoable configuration transaction retained across launches.
///
/// The entry intentionally stores only the receipt's hashes and backup URLs plus
/// profile display metadata. It never stores credentials, configuration text, or
/// Codex session data.
public struct SwitchReceiptJournalEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let receipt: SwitchReceipt
    public let createdAt: Date
    public let profileName: String?
    public let model: String?
    public let providerDisplayName: String?

    public init(
        id: UUID = UUID(),
        receipt: SwitchReceipt,
        createdAt: Date = Date(),
        profileName: String? = nil,
        model: String? = nil,
        providerDisplayName: String? = nil
    ) {
        self.id = id
        self.receipt = receipt
        self.createdAt = createdAt
        self.profileName = profileName
        self.model = model
        self.providerDisplayName = providerDisplayName
    }
}

/// Errors emitted when a receipt journal cannot be changed safely.
public enum SwitchReceiptRepositoryError: LocalizedError, Equatable, Sendable {
    case unableToWriteJournal
    case unableToDeleteJournal

    public var errorDescription: String? {
        switch self {
        case .unableToWriteJournal:
            return L10n.tr("The switch journal could not be written safely.")
        case .unableToDeleteJournal:
            return L10n.tr("The switch journal could not be updated safely.")
        }
    }
}

/// Persists a small, private history of switch receipts for undo after relaunch.
///
/// Corrupt or unreadable journal data is treated as an empty history. Its raw
/// bytes are never surfaced through this API. This repository is deliberately
/// unrelated to Codex session, history, auth, or state files.
public actor SwitchReceiptRepository {
    public static let maximumEntries = 20
    public static let maximumJournalBytes = 1_048_576

    public static var defaultStorageURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )

        return applicationSupport
            .appendingPathComponent("AllInOneCodex", isDirectory: true)
            .appendingPathComponent("switch-receipts.json", isDirectory: false)
    }

    public let storageURL: URL

    public init(storageURL: URL = SwitchReceiptRepository.defaultStorageURL) {
        self.storageURL = storageURL
    }

    /// Returns retained entries newest-first. A corrupt journal safely appears
    /// empty so callers never need to inspect potentially sensitive raw bytes.
    public func load() -> [SwitchReceiptJournalEntry] {
        normalizedEntries(from: readEntries())
    }

    /// Saves one completed switch using only profile display metadata.
    @discardableResult
    public func save(
        receipt: SwitchReceipt,
        profile: ProviderProfile
    ) throws -> SwitchReceiptJournalEntry {
        let providerDisplayName = ProviderCatalog.preset(for: profile.presetID)?
            .displayName ?? profile.presetID.rawValue
        return try save(
            receipt: receipt,
            profileName: profile.name,
            model: profile.model,
            providerDisplayName: providerDisplayName,
            createdAt: receipt.timestamp
        )
    }

    /// Saves one completed switch with UI-safe display metadata.
    @discardableResult
    public func save(
        receipt: SwitchReceipt,
        profileName: String?,
        model: String?,
        providerDisplayName: String?,
        createdAt: Date? = nil
    ) throws -> SwitchReceiptJournalEntry {
        let entry = SwitchReceiptJournalEntry(
            receipt: receipt,
            createdAt: createdAt ?? receipt.timestamp,
            profileName: profileName,
            model: model,
            providerDisplayName: providerDisplayName
        )
        try save(entry)
        return entry
    }

    /// Alias for App-facing integration code that describes the action as
    /// persisting a receipt rather than saving a generic journal entry.
    @discardableResult
    public func persist(
        receipt: SwitchReceipt,
        profile: ProviderProfile
    ) throws -> SwitchReceiptJournalEntry {
        try save(receipt: receipt, profile: profile)
    }

    /// Adds or replaces a journal entry and retains only the newest entries.
    public func save(_ entry: SwitchReceiptJournalEntry) throws {
        var entries = readEntries()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        try write(normalizedEntries(from: entries))
    }

    /// Removes an entry after a successful undo or explicit dismissal.
    public func delete(id: UUID) throws {
        var entries = readEntries()
        entries.removeAll { $0.id == id }
        do {
            try write(normalizedEntries(from: entries))
        } catch {
            throw SwitchReceiptRepositoryError.unableToDeleteJournal
        }
    }

    public func delete(_ entry: SwitchReceiptJournalEntry) throws {
        try delete(id: entry.id)
    }

    private func readEntries() -> [SwitchReceiptJournalEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return []
        }

        guard
            let data = try? Data(contentsOf: storageURL),
            data.count <= Self.maximumJournalBytes
        else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let document = try? decoder.decode(JournalDocument.self, from: data) {
            return document.entries
        }
        if let entries = try? decoder.decode([SwitchReceiptJournalEntry].self, from: data) {
            return entries
        }
        if let legacyReceipts = try? decoder.decode([SwitchReceipt].self, from: data) {
            return legacyReceipts.map {
                SwitchReceiptJournalEntry(
                    receipt: $0,
                    createdAt: $0.timestamp
                )
            }
        }
        return []
    }

    private func normalizedEntries(
        from entries: [SwitchReceiptJournalEntry]
    ) -> [SwitchReceiptJournalEntry] {
        Array(
            entries
                .sorted {
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.id.uuidString > $1.id.uuidString
                }
                .prefix(Self.maximumEntries)
        )
    }

    private func write(_ entries: [SwitchReceiptJournalEntry]) throws {
        let directoryURL = storageURL.deletingLastPathComponent()
        do {
            try ensurePrivateDirectory(directoryURL)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                JournalDocument(version: 1, entries: entries)
            )
            try atomicallyWrite(data, to: storageURL)
        } catch is SwitchReceiptRepositoryError {
            throw SwitchReceiptRepositoryError.unableToWriteJournal
        } catch {
            throw SwitchReceiptRepositoryError.unableToWriteJournal
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
            throw SwitchReceiptRepositoryError.unableToWriteJournal
        }

        guard directoryURL.path.withCString({ Darwin.chmod($0, mode_t(0o700)) }) == 0 else {
            throw SwitchReceiptRepositoryError.unableToWriteJournal
        }
    }

    private func atomicallyWrite(_ data: Data, to destination: URL) throws {
        let directoryURL = destination.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let fileDescriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard fileDescriptor >= 0 else {
            throw SwitchReceiptRepositoryError.unableToWriteJournal
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
            throw SwitchReceiptRepositoryError.unableToWriteJournal
        }
        guard Darwin.close(descriptor) == 0 else {
            throw SwitchReceiptRepositoryError.unableToWriteJournal
        }
        descriptor = -1

        let renamed = temporaryURL.path.withCString { temporaryPath in
            destination.path.withCString { destinationPath in
                Darwin.rename(temporaryPath, destinationPath) == 0
            }
        }
        guard renamed else {
            throw SwitchReceiptRepositoryError.unableToWriteJournal
        }
        shouldRemoveTemporaryFile = false

        guard destination.path.withCString({ Darwin.chmod($0, mode_t(0o600)) }) == 0 else {
            throw SwitchReceiptRepositoryError.unableToWriteJournal
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
}

private struct JournalDocument: Codable {
    let version: Int?
    let entries: [SwitchReceiptJournalEntry]
}
