import Foundation

/// The built-in provider families supported by the first release.
public enum ProviderPresetID: String, Codable, CaseIterable, Sendable {
    case openCodeGo
    case openRouter
}

/// Immutable connection details for a supported provider family.
public struct ProviderPreset: Identifiable, Hashable, Sendable {
    public let id: ProviderPresetID
    public let displayName: String
    public let baseURL: String
    public let defaultModel: String
    public let providerID: String

    public init(
        id: ProviderPresetID,
        displayName: String,
        baseURL: String,
        defaultModel: String,
        providerID: String
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.providerID = providerID
    }
}

/// Catalog of provider presets owned by the application.
public enum ProviderCatalog {
    public static let all: [ProviderPreset] = [
        ProviderPreset(
            id: .openCodeGo,
            displayName: "OpenCode Go",
            baseURL: "https://opencode.ai/zen/go/v1",
            defaultModel: "gpt-5.6-luna",
            providerID: "all_in_one_opencode_go"
        ),
        ProviderPreset(
            id: .openRouter,
            displayName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openai/gpt-5.3-codex",
            providerID: "all_in_one_openrouter"
        )
    ]

    public static func preset(for id: ProviderPresetID) -> ProviderPreset? {
        all.first { $0.id == id }
    }
}

/// A user-created provider configuration. Its credential is kept separately in Keychain.
public struct ProviderProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var presetID: ProviderPresetID
    public var model: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        presetID: ProviderPresetID,
        model: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.presetID = presetID
        self.model = model ?? ProviderCatalog.preset(for: presetID)?.defaultModel ?? ""
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
