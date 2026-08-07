import Foundation

/// Persists non-secret provider profile metadata in Application Support.
public actor ProfileRepository {
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

        let data = try Data(contentsOf: storageURL)
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
