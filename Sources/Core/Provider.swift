import Foundation

/// The built-in provider families supported by the first release.
public enum ProviderPresetID: String, Codable, CaseIterable, Sendable {
    case openCodeGo
    case openRouter
}

/// The HTTP contract a model exposes to its provider.
///
/// Codex uses the Responses contract. Chat-only models are deliberately
/// distinguished so they can be routed through the local bridge rather than
/// accidentally configured as native Responses models.
public enum ProviderWireAPI: String, Codable, CaseIterable, Sendable {
    case responses = "responses"
    case chatCompletions = "chat_completions"
    case anthropicMessages = "anthropic_messages"
}

/// A model advertised by a built-in provider together with its wire contract.
public struct ProviderModelDescriptor: Identifiable, Hashable, Sendable {
    public let modelID: String
    public let wireAPI: ProviderWireAPI

    public var id: String { modelID }

    public init(modelID: String, wireAPI: ProviderWireAPI) {
        self.modelID = modelID
        self.wireAPI = wireAPI
    }
}

/// The concrete provider entry Codex should use for a selected profile.
public struct ProviderRoute: Equatable, Sendable {
    public let model: String
    public let providerID: String
    public let baseURL: String
    public let wireAPI: ProviderWireAPI
    public let requiresLoopbackBridge: Bool
    /// The endpoint the loopback bridge contacts when session preservation is
    /// enabled. For direct Responses providers this is identical to `baseURL`;
    /// Chat Completions profiles keep their Codex-facing bridge URL separate
    /// from their upstream endpoint.
    let upstreamBaseURL: String
    /// The wire contract used by `upstreamBaseURL`. This can differ from the
    /// Codex-facing `wireAPI` for a Chat Completions bridge route.
    let upstreamWireAPI: ProviderWireAPI

    public init(
        model: String,
        providerID: String,
        baseURL: String,
        wireAPI: ProviderWireAPI,
        requiresLoopbackBridge: Bool
    ) {
        self.init(
            model: model,
            providerID: providerID,
            baseURL: baseURL,
            wireAPI: wireAPI,
            requiresLoopbackBridge: requiresLoopbackBridge,
            upstreamBaseURL: baseURL,
            upstreamWireAPI: wireAPI
        )
    }

    init(
        model: String,
        providerID: String,
        baseURL: String,
        wireAPI: ProviderWireAPI,
        requiresLoopbackBridge: Bool,
        upstreamBaseURL: String,
        upstreamWireAPI: ProviderWireAPI
    ) {
        self.model = model
        self.providerID = providerID
        self.baseURL = baseURL
        self.wireAPI = wireAPI
        self.requiresLoopbackBridge = requiresLoopbackBridge
        self.upstreamBaseURL = upstreamBaseURL
        self.upstreamWireAPI = upstreamWireAPI
    }
}

/// Errors returned when a profile cannot be represented safely by Codex.
public enum ProviderRoutingError: LocalizedError, Equatable, Sendable {
    case invalidModel
    case unknownOpenCodeGoModel
    case unsupportedOpenCodeGoWireAPI(ProviderWireAPI)

    public var errorDescription: String? {
        switch self {
        case .invalidModel:
            return "The selected model is empty."
        case .unknownOpenCodeGoModel:
            return "This OpenCode Go model is not in the supported capability catalog."
        case .unsupportedOpenCodeGoWireAPI(.anthropicMessages):
            return "This OpenCode Go model uses the Anthropic Messages API, which the bridge does not support yet."
        case .unsupportedOpenCodeGoWireAPI:
            return "This OpenCode Go model uses an unsupported provider API."
        }
    }
}

/// Immutable connection details for a supported provider family.
public struct ProviderPreset: Identifiable, Hashable, Sendable {
    public let id: ProviderPresetID
    public let displayName: String
    public let baseURL: String
    public let defaultModel: String
    public let providerID: String
    public let modelDescriptors: [ProviderModelDescriptor]
    public let allowsCustomModels: Bool

    public init(
        id: ProviderPresetID,
        displayName: String,
        baseURL: String,
        defaultModel: String,
        providerID: String,
        modelDescriptors: [ProviderModelDescriptor] = [],
        allowsCustomModels: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.providerID = providerID
        self.modelDescriptors = modelDescriptors
        self.allowsCustomModels = allowsCustomModels
    }
}

/// Catalog of provider presets owned by the application.
public enum ProviderCatalog {
    public static let openCodeGoOfficialBaseURL = "https://opencode.ai/zen/go/v1"
    public static let openCodeGoBridgeBaseURL = "http://127.0.0.1:14556/v1"
    public static let openCodeGoResponsesProviderID = "all_in_one_opencode_go"
    public static let openCodeGoBridgeProviderID = "all_in_one_opencode_go_bridge"
    public static let openRouterProviderID = "all_in_one_openrouter"

    public static let openCodeGoModels: [ProviderModelDescriptor] = [
        ProviderModelDescriptor(modelID: "gpt-5.6-luna", wireAPI: .responses),

        ProviderModelDescriptor(modelID: "grok-4.5", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "glm-5.2", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "glm-5.1", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "kimi-k3", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "kimi-k2.7-code", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "kimi-k2.6", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "deepseek-v4-pro", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "deepseek-v4-flash", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "mimo-v2.5", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "mimo-v2.5-pro", wireAPI: .chatCompletions),
        ProviderModelDescriptor(modelID: "hy3", wireAPI: .chatCompletions),

        ProviderModelDescriptor(modelID: "minimax-m3", wireAPI: .anthropicMessages),
        ProviderModelDescriptor(modelID: "minimax-m2.7", wireAPI: .anthropicMessages),
        ProviderModelDescriptor(modelID: "qwen3.8-max", wireAPI: .anthropicMessages),
        ProviderModelDescriptor(modelID: "qwen3.7-max", wireAPI: .anthropicMessages),
        ProviderModelDescriptor(modelID: "qwen3.7-plus", wireAPI: .anthropicMessages),
        ProviderModelDescriptor(modelID: "qwen3.6-plus", wireAPI: .anthropicMessages)
    ]

    public static let all: [ProviderPreset] = [
        ProviderPreset(
            id: .openCodeGo,
            displayName: "OpenCode Go",
            baseURL: openCodeGoOfficialBaseURL,
            defaultModel: "glm-5.2",
            providerID: openCodeGoBridgeProviderID,
            modelDescriptors: openCodeGoModels
        ),
        ProviderPreset(
            id: .openRouter,
            displayName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openai/gpt-5.3-codex",
            providerID: openRouterProviderID,
            allowsCustomModels: true
        )
    ]

    public static func preset(for id: ProviderPresetID) -> ProviderPreset? {
        all.first { $0.id == id }
    }

    /// Returns the model's catalog entry. OpenRouter intentionally allows
    /// arbitrary model IDs and always uses Codex's Responses protocol.
    public static func descriptor(
        for model: String,
        presetID: ProviderPresetID
    ) -> ProviderModelDescriptor? {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return nil
        }

        switch presetID {
        case .openCodeGo:
            return openCodeGoModels.first { $0.modelID == trimmedModel }
        case .openRouter:
            return ProviderModelDescriptor(
                modelID: trimmedModel,
                wireAPI: .responses
            )
        }
    }

    /// Resolves a profile into the exact Codex provider configuration.
    ///
    /// Anthropic Messages models are intentionally rejected. Treating them as
    /// Chat Completions would silently send malformed requests upstream.
    public static func route(for profile: ProviderProfile) throws -> ProviderRoute {
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw ProviderRoutingError.invalidModel
        }

        switch profile.presetID {
        case .openRouter:
            guard let preset = preset(for: .openRouter) else {
                throw ProviderRoutingError.invalidModel
            }
            return ProviderRoute(
                model: model,
                providerID: preset.providerID,
                baseURL: preset.baseURL,
                wireAPI: .responses,
                requiresLoopbackBridge: false
            )

        case .openCodeGo:
            guard let descriptor = descriptor(for: model, presetID: .openCodeGo) else {
                throw ProviderRoutingError.unknownOpenCodeGoModel
            }

            switch descriptor.wireAPI {
            case .responses:
                return ProviderRoute(
                    model: model,
                    providerID: openCodeGoResponsesProviderID,
                    baseURL: openCodeGoOfficialBaseURL,
                    wireAPI: .responses,
                    requiresLoopbackBridge: false
                )
            case .chatCompletions:
                return ProviderRoute(
                    model: model,
                    providerID: openCodeGoBridgeProviderID,
                    baseURL: openCodeGoBridgeBaseURL,
                    wireAPI: .responses,
                    requiresLoopbackBridge: true,
                    upstreamBaseURL: openCodeGoOfficialBaseURL,
                    upstreamWireAPI: .chatCompletions
                )
            case .anthropicMessages:
                throw ProviderRoutingError.unsupportedOpenCodeGoWireAPI(.anthropicMessages)
            }
        }
    }
}

/// A user-created provider configuration. Its credential is kept separately in Keychain.
public struct ProviderProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var presetID: ProviderPresetID
    public var model: String
    /// Opt-in only. When enabled the app leaves Codex on its OpenAI provider
    /// identity and routes requests through the authenticated local bridge so
    /// existing Codex session history can remain associated with that identity.
    public var preserveSessions: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        presetID: ProviderPresetID,
        model: String? = nil,
        preserveSessions: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.presetID = presetID
        self.model = model ?? ProviderCatalog.preset(for: presetID)?.defaultModel ?? ""
        self.preserveSessions = preserveSessions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case presetID
        case model
        case preserveSessions
        case createdAt
        case updatedAt
    }

    /// Profiles persisted before session preservation existed deliberately
    /// decode as opt-out, rather than failing migration or changing their
    /// routing behavior.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        presetID = try container.decode(ProviderPresetID.self, forKey: .presetID)
        model = try container.decode(String.self, forKey: .model)
        preserveSessions = try container.decodeIfPresent(
            Bool.self,
            forKey: .preserveSessions
        ) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(presetID, forKey: .presetID)
        try container.encode(model, forKey: .model)
        try container.encode(preserveSessions, forKey: .preserveSessions)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
