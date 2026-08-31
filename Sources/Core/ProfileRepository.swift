import Foundation

/// Persists non-secret provider profile metadata in Application Support.
public actor ProfileRepository {
    public static let maximumStorageBytes = 1 * 1024 * 1024

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
            .appendingPathComponent("profiles.json", isDirectory: false)
    }

    public let storageURL: URL

    public init(storageURL: URL = ProfileRepository.defaultStorageURL) {
        self.storageURL = storageURL
    }

    public func load() throws -> [ProviderProfile] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return []
        }

        // Repair permissions for files created by an older build before
        // reading profile metadata. Credentials are not stored here, but the
        // profile IDs and provider choices are still user-private.
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: storageURL.deletingLastPathComponent().path
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path
        )

        guard
            let values = try? storageURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size <= Int64(Self.maximumStorageBytes)
        else {
            throw CocoaError(.fileReadTooLarge)
        }
        let handle = try FileHandle(forReadingFrom: storageURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumStorageBytes + 1) ?? Data()
        guard data.count <= Self.maximumStorageBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([ProviderProfile].self, from: data)
    }

    public func save(_ profiles: [ProviderProfile]) throws {
        let fileManager = FileManager.default
        let directoryURL = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: storageURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path
        )
    }
}
