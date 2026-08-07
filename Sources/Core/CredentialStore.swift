import Foundation
import Security

/// Errors intentionally omit credential contents and Keychain query details.
public enum CredentialStoreError: LocalizedError, Equatable, Sendable {
    case emptyCredential
    case notFound
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .emptyCredential:
            return "The credential cannot be empty."
        case .notFound:
            return "No credential is stored for this profile."
        case .unavailable:
            return "The credential store is unavailable."
        }
    }
}

/// Storage abstraction that keeps credentials outside application configuration files.
public protocol CredentialStoring: AnyObject {
    func save(_ credential: Data, for profileID: UUID) throws
    func read(for profileID: UUID) throws -> Data
    func delete(for profileID: UUID) throws
    func contains(for profileID: UUID) -> Bool
}

public extension CredentialStoring {
    /// Availability checks must not expose or retain the credential bytes.
    func contains(for profileID: UUID) -> Bool {
        guard let credential = try? read(for: profileID) else {
            return false
        }
        return !credential.isEmpty
    }
}

/// A Keychain-backed credential store. Each profile UUID is the Keychain account.
public final class KeychainCredentialStore: CredentialStoring {
    public static let service = "com.allinonecodex.provider-key"

    public init() {}

    public func save(_ credential: Data, for profileID: UUID) throws {
        guard !credential.isEmpty else {
            throw CredentialStoreError.emptyCredential
        }

        let query = baseQuery(for: profileID)
        let update: [CFString: Any] = [
            kSecValueData: credential
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.unavailable
        }

        var item = query
        item[kSecValueData] = credential
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw CredentialStoreError.unavailable
        }
    }

    /// Convenience overload for API-key text entered by the UI.
    public func save(_ credential: String, for profileID: UUID) throws {
        guard let data = credential.data(using: .utf8) else {
            throw CredentialStoreError.emptyCredential
        }
        try save(data, for: profileID)
    }

    public func read(for profileID: UUID) throws -> Data {
        var query = baseQuery(for: profileID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            throw CredentialStoreError.notFound
        }
        guard status == errSecSuccess, let credential = result as? Data else {
            throw CredentialStoreError.unavailable
        }
        return credential
    }

    public func contains(for profileID: UUID) -> Bool {
        var query = baseQuery(for: profileID)
        query[kSecReturnData] = false
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func delete(for profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unavailable
        }
    }

    private func baseQuery(for profileID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: profileID.uuidString
        ]
    }
}
