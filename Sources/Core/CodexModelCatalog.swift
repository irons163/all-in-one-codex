import Foundation

/// Validation failures for the app-owned Codex model catalog.
///
/// The cases intentionally avoid carrying catalog contents because a custom
/// model identifier should never be reflected through a configuration error.
public enum CodexModelCatalogError: LocalizedError, Equatable, Sendable {
    case emptyModels
    case tooManyModels
    case duplicateModel
    case invalidModelIdentifier
    case invalidSchema
    case catalogTooLarge
    case unreadableCatalog
    case unsafeCatalogPath

    public var errorDescription: String? {
        switch self {
        case .emptyModels:
            return "The Codex model catalog does not contain any models."
        case .tooManyModels:
            return "The Codex model catalog contains too many models."
        case .duplicateModel:
            return "The Codex model catalog contains duplicate model entries."
        case .invalidModelIdentifier:
            return "The selected model cannot be represented safely in the Codex catalog."
        case .invalidSchema:
            return "The Codex model catalog has an unsupported schema."
        case .catalogTooLarge:
            return "The Codex model catalog exceeds the supported size limit."
        case .unreadableCatalog:
            return "The Codex model catalog could not be read safely."
        case .unsafeCatalogPath:
            return "The Codex model catalog path is unsafe."
        }
    }
}

/// A reasoning level accepted by Codex's external model-catalog schema.
public struct CodexModelCatalogReasoningLevel: Codable, Equatable, Hashable, Sendable {
    public let effort: String
    public let description: String

    public init(effort: String, description: String) {
        self.effort = effort
        self.description = description
    }
}

/// The truncation policy included by the cc-switch native Responses fixture.
public struct CodexModelCatalogTruncationPolicy: Codable, Equatable, Hashable, Sendable {
    public let mode: String
    public let limit: Int

    public init(mode: String, limit: Int) {
        self.mode = mode
        self.limit = limit
    }
}

/// One entry in Codex's external `model_catalog_json` document.
///
/// The fields mirror the minimal, parser-compatible shape in cc-switch's
/// `codex_native_responses_template.json`. In particular,
/// `base_instructions` and `supports_reasoning_summaries` are retained because
/// cc-switch documents them as required by current Codex catalog parsers.
public struct CodexModelCatalogEntry: Codable, Equatable, Hashable, Sendable {
    public let slug: String
    public let displayName: String
    public let description: String
    public let baseInstructions: String
    public let defaultReasoningLevel: String
    public let supportedReasoningLevels: [CodexModelCatalogReasoningLevel]
    public let shellType: String
    public let visibility: String
    public let supportedInAPI: Bool
    public let priority: Int
    public let supportsReasoningSummaries: Bool
    public let defaultReasoningSummary: String
    public let supportVerbosity: Bool
    public let truncationPolicy: CodexModelCatalogTruncationPolicy
    public let supportsParallelToolCalls: Bool
    public let supportsImageDetailOriginal: Bool
    public let contextWindow: Int
    public let maxContextWindow: Int
    public let effectiveContextWindowPercent: Int
    public let experimentalSupportedTools: [String]
    public let inputModalities: [String]
    public let supportsSearchTool: Bool

    public init(
        slug: String,
        displayName: String,
        description: String,
        baseInstructions: String,
        defaultReasoningLevel: String,
        supportedReasoningLevels: [CodexModelCatalogReasoningLevel],
        shellType: String,
        visibility: String,
        supportedInAPI: Bool,
        priority: Int,
        supportsReasoningSummaries: Bool,
        defaultReasoningSummary: String,
        supportVerbosity: Bool,
        truncationPolicy: CodexModelCatalogTruncationPolicy,
        supportsParallelToolCalls: Bool,
        supportsImageDetailOriginal: Bool,
        contextWindow: Int,
        maxContextWindow: Int,
        effectiveContextWindowPercent: Int,
        experimentalSupportedTools: [String],
        inputModalities: [String],
        supportsSearchTool: Bool
    ) {
        self.slug = slug
        self.displayName = displayName
        self.description = description
        self.baseInstructions = baseInstructions
        self.defaultReasoningLevel = defaultReasoningLevel
        self.supportedReasoningLevels = supportedReasoningLevels
        self.shellType = shellType
        self.visibility = visibility
        self.supportedInAPI = supportedInAPI
        self.priority = priority
        self.supportsReasoningSummaries = supportsReasoningSummaries
        self.defaultReasoningSummary = defaultReasoningSummary
        self.supportVerbosity = supportVerbosity
        self.truncationPolicy = truncationPolicy
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.supportsImageDetailOriginal = supportsImageDetailOriginal
        self.contextWindow = contextWindow
        self.maxContextWindow = maxContextWindow
        self.effectiveContextWindowPercent = effectiveContextWindowPercent
        self.experimentalSupportedTools = experimentalSupportedTools
        self.inputModalities = inputModalities
        self.supportsSearchTool = supportsSearchTool
    }

    private enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case description
        case baseInstructions = "base_instructions"
        case defaultReasoningLevel = "default_reasoning_level"
        case supportedReasoningLevels = "supported_reasoning_levels"
        case shellType = "shell_type"
        case visibility
        case supportedInAPI = "supported_in_api"
        case priority
        case supportsReasoningSummaries = "supports_reasoning_summaries"
        case defaultReasoningSummary = "default_reasoning_summary"
        case supportVerbosity = "support_verbosity"
        case truncationPolicy = "truncation_policy"
        case supportsParallelToolCalls = "supports_parallel_tool_calls"
        case supportsImageDetailOriginal = "supports_image_detail_original"
        case contextWindow = "context_window"
        case maxContextWindow = "max_context_window"
        case effectiveContextWindowPercent = "effective_context_window_percent"
        case experimentalSupportedTools = "experimental_supported_tools"
        case inputModalities = "input_modalities"
        case supportsSearchTool = "supports_search_tool"
    }
}

/// App-owned Codex model catalog stored beside `config.toml`.
public struct CodexModelCatalog: Codable, Equatable, Sendable {
    public static let filename = "all-in-one-codex-model-catalog.json"
    public static let maximumCatalogBytes = 1_048_576
    public static let defaultContextWindow = 128_000
    public static let maximumModelCount = 64

    public let models: [CodexModelCatalogEntry]

    public init(models: [CodexModelCatalogEntry]) throws {
        self.models = models
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decode([CodexModelCatalogEntry].self, forKey: .models)
        try validate()
    }

    public func validate() throws {
        guard !models.isEmpty else {
            throw CodexModelCatalogError.emptyModels
        }
        guard models.count <= Self.maximumModelCount else {
            throw CodexModelCatalogError.tooManyModels
        }

        var seen = Set<String>()
        for entry in models {
            guard Self.isSafeModelIdentifier(entry.slug) else {
                throw CodexModelCatalogError.invalidModelIdentifier
            }
            guard seen.insert(entry.slug).inserted else {
                throw CodexModelCatalogError.duplicateModel
            }
            guard
                !entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !entry.baseInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !entry.defaultReasoningLevel.isEmpty,
                !entry.supportedReasoningLevels.isEmpty,
                entry.shellType == "shell_command",
                entry.visibility == "list",
                entry.supportedInAPI,
                entry.supportsReasoningSummaries,
                entry.contextWindow > 0,
                entry.maxContextWindow >= entry.contextWindow,
                (1...100).contains(entry.effectiveContextWindowPercent),
                entry.truncationPolicy.limit > 0,
                !entry.inputModalities.isEmpty
            else {
                throw CodexModelCatalogError.invalidSchema
            }
        }
    }

    public func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumCatalogBytes else {
            throw CodexModelCatalogError.catalogTooLarge
        }
        return data
    }

    public static func decodeValidated(from data: Data) throws -> CodexModelCatalog {
        guard data.count <= maximumCatalogBytes else {
            throw CodexModelCatalogError.catalogTooLarge
        }
        do {
            let catalog = try JSONDecoder().decode(CodexModelCatalog.self, from: data)
            try catalog.validate()
            return catalog
        } catch let error as CodexModelCatalogError {
            throw error
        } catch {
            throw CodexModelCatalogError.unreadableCatalog
        }
    }

    /// Builds the selectable model list for one provider profile. OpenCode Go
    /// advertises every supported Responses/Chat descriptor; an OpenRouter
    /// profile advertises its selected custom model without serializing any
    /// connection or credential data.
    public static func make(for profile: ProviderProfile) throws -> CodexModelCatalog {
        _ = try ProviderCatalog.route(for: profile)
        let modelIDs: [String]

        switch profile.presetID {
        case .openCodeGo:
            modelIDs = bridgeModelIDs
        case .openRouter:
            modelIDs = [profile.model.trimmingCharacters(in: .whitespacesAndNewlines)]
        }

        return try CodexModelCatalog(
            models: modelIDs.enumerated().map { index, modelID in
                entry(for: modelID, priority: 1_000 + index)
            }
        )
    }

    /// The local bridge serves exactly this catalog-derived model list through
    /// the OpenAI-compatible `/models` and `/v1/models` endpoints.
    public static func bridgeModelListResponse() -> OpenAIModelListResponse {
        OpenAIModelListResponse(
            modelIDs: bridgeModelIDs
        )
    }

    public static func catalogURL(for configurationURL: URL) throws -> URL {
        let standardizedConfigurationURL = configurationURL.standardizedFileURL
        let directoryURL = standardizedConfigurationURL.deletingLastPathComponent()

        guard
            standardizedConfigurationURL.lastPathComponent == "config.toml",
            directoryURL.lastPathComponent == ".codex"
        else {
            throw CodexModelCatalogError.unsafeCatalogPath
        }

        let catalogURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
        guard catalogURL.deletingLastPathComponent().standardizedFileURL == directoryURL else {
            throw CodexModelCatalogError.unsafeCatalogPath
        }
        return catalogURL
    }

    /// Rejects a catalog path that reaches outside the configuration directory
    /// through a pre-existing symlink.
    public static func validateOwnedCatalogURL(
        _ catalogURL: URL,
        for configurationURL: URL
    ) throws {
        let expectedURL = try self.catalogURL(for: configurationURL)
        guard catalogURL.standardizedFileURL == expectedURL.standardizedFileURL else {
            throw CodexModelCatalogError.unsafeCatalogPath
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: expectedURL.path) else {
            return
        }

        let resolvedDirectory = expectedURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedCatalog = expectedURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCatalog.deletingLastPathComponent() == resolvedDirectory else {
            throw CodexModelCatalogError.unsafeCatalogPath
        }
    }

    public static var bridgeModelIDs: [String] {
        ProviderCatalog.openCodeGoModels
            .filter {
                $0.wireAPI == .responses || $0.wireAPI == .chatCompletions
            }
            .map(\.modelID)
    }

    private static func entry(for modelID: String, priority: Int) -> CodexModelCatalogEntry {
        CodexModelCatalogEntry(
            slug: modelID,
            displayName: modelID,
            description: modelID,
            baseInstructions: "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals.",
            defaultReasoningLevel: "high",
            supportedReasoningLevels: [
                CodexModelCatalogReasoningLevel(
                    effort: "none",
                    description: "Disable Thinking"
                ),
                CodexModelCatalogReasoningLevel(
                    effort: "high",
                    description: "Enabled Thinking"
                )
            ],
            shellType: "shell_command",
            visibility: "list",
            supportedInAPI: true,
            priority: priority,
            supportsReasoningSummaries: true,
            defaultReasoningSummary: "none",
            supportVerbosity: false,
            truncationPolicy: CodexModelCatalogTruncationPolicy(
                mode: "bytes",
                limit: 10_000
            ),
            supportsParallelToolCalls: false,
            supportsImageDetailOriginal: false,
            contextWindow: defaultContextWindow,
            maxContextWindow: defaultContextWindow,
            effectiveContextWindowPercent: 95,
            experimentalSupportedTools: [],
            inputModalities: ["text"],
            supportsSearchTool: false
        )
    }

    private static func isSafeModelIdentifier(_ modelID: String) -> Bool {
        let scalars = modelID.unicodeScalars
        guard (1...200).contains(scalars.count) else {
            return false
        }

        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._:/"
        )
        return scalars.allSatisfy(allowed.contains)
    }
}

/// OpenAI-compatible model-list payload used by the local bridge.
public struct OpenAIModelListResponse: Codable, Equatable, Sendable {
    public let object: String
    public let data: [OpenAIModelListEntry]

    public init(modelIDs: [String]) {
        object = "list"
        data = modelIDs.map { OpenAIModelListEntry(id: $0) }
    }
}

public struct OpenAIModelListEntry: Codable, Equatable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let ownedBy: String

    public init(id: String) {
        self.id = id
        object = "model"
        created = 0
        ownedBy = "all-in-one-codex"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
    }
}
