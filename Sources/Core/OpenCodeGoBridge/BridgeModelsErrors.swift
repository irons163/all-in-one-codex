import Foundation

/// Runtime state of the local loopback bridge.
public enum OpenCodeGoBridgeStatus: String, Codable, Equatable, Sendable {
    case running
    case stopped
}

/// Lifecycle boundary for the local Responses-to-Chat Completions bridge.
public protocol OpenCodeGoBridgeManaging: AnyObject {
    var status: OpenCodeGoBridgeStatus { get }
    func ensureRunning() throws
    func stop()
}

public extension OpenCodeGoBridgeManaging {
    var status: OpenCodeGoBridgeStatus {
        .stopped
    }
}

/// Internal configuration boundary used by `CodexClientAdapter`. Keeping the
/// credential-bearing mode off the public lifecycle protocol preserves the
/// lightweight test/alternate-manager contract while ensuring only the
/// loopback manager can retain the in-memory Keychain value.
protocol OpenCodeGoBridgeConfiguring: AnyObject {
    func configureLegacyChatMode()
    func configurePreservingSessions(
        route: ProviderRoute,
        credential: Data
    )
}

/// Errors are deliberately generic so neither bearer credentials nor upstream
/// response bodies can reach configuration, logs, or UI error strings.
public enum OpenCodeGoBridgeError: LocalizedError, Equatable, Sendable {
    case portInUse
    case unableToStart
    case requestTooLarge
    case contentLengthRequired
    case invalidContentLength
    case unsupportedContentEncoding
    case invalidRequest
    case unsupportedModel
    case missingAuthorization
    case missingProviderCredential
    case upstreamUnavailable
    case upstreamRejected
    case invalidUpstreamResponse

    public var errorDescription: String? {
        switch self {
        case .portInUse:
            return "The OpenCode Go bridge port 14556 is already in use."
        case .unableToStart:
            return "The OpenCode Go bridge could not start."
        case .requestTooLarge:
            return "The bridge request exceeds the supported size limit."
        case .contentLengthRequired:
            return "The bridge requires a Content-Length request body."
        case .invalidContentLength:
            return "The bridge received an invalid Content-Length header."
        case .unsupportedContentEncoding:
            return "The bridge does not support this request content encoding."
        case .invalidRequest:
            return "The bridge received an unsupported Responses request."
        case .unsupportedModel:
            return "The bridge supports only known OpenCode Go Chat Completions models."
        case .missingAuthorization:
            return "The bridge request did not include provider authorization."
        case .missingProviderCredential:
            return "The bridge has no active provider credential."
        case .upstreamUnavailable:
            return "OpenCode Go is temporarily unavailable."
        case .upstreamRejected:
            return "OpenCode Go rejected the request."
        case .invalidUpstreamResponse:
            return "OpenCode Go returned an unsupported Chat Completions response."
        }
    }
}

/// A sanitized error suitable for a local HTTP response or Responses SSE event.
public struct OpenCodeGoNormalizedError: Equatable, Sendable {
    public let statusCode: Int
    public let code: String
    public let message: String

    public init(statusCode: Int, code: String, message: String) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
    }
}

/// Maps bridge and URLSession failures without exposing raw provider output.
public enum OpenCodeGoBridgeErrorNormalizer {
    public static func normalize(
        _ error: Error,
        upstreamStatusCode: Int? = nil
    ) -> OpenCodeGoNormalizedError {
        if let upstreamStatusCode {
            switch upstreamStatusCode {
            case 400:
                return OpenCodeGoNormalizedError(
                    statusCode: 400,
                    code: "upstream_invalid_request",
                    message: "OpenCode Go rejected the converted request."
                )
            case 401:
                return OpenCodeGoNormalizedError(
                    statusCode: 401,
                    code: "upstream_authentication_failed",
                    message: "OpenCode Go rejected the provider authorization."
                )
            case 403:
                return OpenCodeGoNormalizedError(
                    statusCode: 403,
                    code: "upstream_access_denied",
                    message: "OpenCode Go denied access to the selected model."
                )
            case 408, 504:
                return OpenCodeGoNormalizedError(
                    statusCode: 504,
                    code: "upstream_timeout",
                    message: "OpenCode Go did not respond in time."
                )
            case 413:
                return OpenCodeGoNormalizedError(
                    statusCode: 413,
                    code: "upstream_request_too_large",
                    message: "OpenCode Go rejected the request size."
                )
            case 429:
                return OpenCodeGoNormalizedError(
                    statusCode: 429,
                    code: "upstream_rate_limited",
                    message: "OpenCode Go is rate limiting this request."
                )
            case 500...599:
                return OpenCodeGoNormalizedError(
                    statusCode: 502,
                    code: "upstream_unavailable",
                    message: "OpenCode Go is temporarily unavailable."
                )
            default:
                return OpenCodeGoNormalizedError(
                    statusCode: 502,
                    code: "upstream_rejected",
                    message: "OpenCode Go rejected the request."
                )
            }
        }

        guard let bridgeError = error as? OpenCodeGoBridgeError else {
            return OpenCodeGoNormalizedError(
                statusCode: 502,
                code: "upstream_unavailable",
                message: "OpenCode Go is temporarily unavailable."
            )
        }

        switch bridgeError {
        case .requestTooLarge:
            return OpenCodeGoNormalizedError(
                statusCode: 413,
                code: "request_too_large",
                message: "The bridge request exceeds the supported size limit."
            )
        case .contentLengthRequired:
            return OpenCodeGoNormalizedError(
                statusCode: 411,
                code: "content_length_required",
                message: "The bridge requires a Content-Length request body."
            )
        case .invalidContentLength, .invalidRequest:
            return OpenCodeGoNormalizedError(
                statusCode: 400,
                code: "invalid_request",
                message: "The bridge received an unsupported Responses request."
            )
        case .unsupportedModel:
            return OpenCodeGoNormalizedError(
                statusCode: 400,
                code: "unsupported_model",
                message: "The bridge supports only known OpenCode Go Chat Completions models."
            )
        case .unsupportedContentEncoding:
            return OpenCodeGoNormalizedError(
                statusCode: 415,
                code: "unsupported_content_encoding",
                message: "The bridge does not support this request content encoding."
            )
        case .missingAuthorization:
            return OpenCodeGoNormalizedError(
                statusCode: 401,
                code: "missing_authorization",
                message: "The bridge request did not include provider authorization."
            )
        case .missingProviderCredential:
            return OpenCodeGoNormalizedError(
                statusCode: 503,
                code: "missing_provider_credential",
                message: "The bridge has no active provider credential."
            )
        case .portInUse:
            return OpenCodeGoNormalizedError(
                statusCode: 503,
                code: "bridge_port_in_use",
                message: "The OpenCode Go bridge port 14556 is already in use."
            )
        case .unableToStart:
            return OpenCodeGoNormalizedError(
                statusCode: 503,
                code: "bridge_unavailable",
                message: "The OpenCode Go bridge could not start."
            )
        case .upstreamRejected:
            return OpenCodeGoNormalizedError(
                statusCode: 502,
                code: "upstream_rejected",
                message: "OpenCode Go rejected the request."
            )
        case .upstreamUnavailable:
            return OpenCodeGoNormalizedError(
                statusCode: 502,
                code: "upstream_unavailable",
                message: "OpenCode Go is temporarily unavailable."
            )
        case .invalidUpstreamResponse:
            return OpenCodeGoNormalizedError(
                statusCode: 502,
                code: "invalid_upstream_response",
                message: "OpenCode Go returned an unsupported Chat Completions response."
            )
        }
    }
}

/// A function call as represented by the Chat Completions API.
public struct OpenCodeGoToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// State required to reconstruct an assistant tool-call turn after Codex sends
/// a Responses `previous_response_id`.
public struct OpenCodeGoToolCallHistory: Equatable, Sendable {
    public let toolCalls: [OpenCodeGoToolCall]
    public let reasoningContent: String?

    public init(toolCalls: [OpenCodeGoToolCall], reasoningContent: String? = nil) {
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
    }
}

/// Bounded, thread-safe in-memory state used to reconstruct Chat tool-call
/// turns. Credentials and raw upstream payloads are never retained.
public final class OpenCodeGoToolCallCache: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [String: OpenCodeGoToolCallHistory] = [:]
    private var insertionOrder: [String] = []

    public init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    public func store(
        responseID: String,
        toolCalls: [OpenCodeGoToolCall],
        reasoningContent: String? = nil
    ) {
        let normalizedReasoning = reasoningContent?.isEmpty == false ? reasoningContent : nil
        guard !responseID.isEmpty, (!toolCalls.isEmpty || normalizedReasoning != nil) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        insertionOrder.removeAll { $0 == responseID }
        entries[responseID] = OpenCodeGoToolCallHistory(
            toolCalls: toolCalls,
            reasoningContent: normalizedReasoning
        )
        insertionOrder.append(responseID)

        while insertionOrder.count > capacity {
            let evictedID = insertionOrder.removeFirst()
            entries.removeValue(forKey: evictedID)
        }
    }

    public func history(for responseID: String) -> OpenCodeGoToolCallHistory? {
        lock.lock()
        defer { lock.unlock() }
        return entries[responseID]
    }

    /// Compatibility accessor for callers that only need function calls.
    public func toolCalls(for responseID: String) -> [OpenCodeGoToolCall]? {
        history(for: responseID)?.toolCalls
    }
}

/// The Responses item kind represented by a flattened Chat function.
public enum OpenCodeGoResponsesToolKind: String, Codable, Hashable, Sendable {
    case function
    case custom
    case toolSearch = "tool_search"
}

/// Per-request metadata required to reverse a Chat function call back into a
/// Responses tool item.
public struct OpenCodeGoToolMapping: Codable, Hashable, Sendable {
    public let chatName: String
    public let responseName: String
    public let kind: OpenCodeGoResponsesToolKind
    public let namespace: String?
    public let description: String?

    public init(
        chatName: String,
        responseName: String,
        kind: OpenCodeGoResponsesToolKind,
        namespace: String? = nil,
        description: String? = nil
    ) {
        self.chatName = chatName
        self.responseName = responseName
        self.kind = kind
        self.namespace = namespace
        self.description = description
    }
}

/// Immutable mapping for one Responses request. It is intentionally scoped to
/// the request so tool metadata from one client turn cannot affect another.
public struct OpenCodeGoToolContext: Codable, Hashable, Sendable {
    public let mappings: [OpenCodeGoToolMapping]

    public init(mappings: [OpenCodeGoToolMapping] = []) {
        self.mappings = mappings
    }

    public func mapping(forChatName name: String) -> OpenCodeGoToolMapping? {
        mappings.first { $0.chatName == name }
    }

    public func chatName(
        forResponseName name: String,
        kind: OpenCodeGoResponsesToolKind? = nil
    ) -> String? {
        mappings.first {
            $0.responseName == name && (kind == nil || $0.kind == kind)
        }?.chatName
    }
}

/// The buffered JSON body that the bridge sends to Chat Completions.
public struct OpenCodeGoChatRequestConversion: Sendable {
    public let body: Data
    public let model: String
    public let previousResponseID: String?
    public let toolContext: OpenCodeGoToolContext

    public init(
        body: Data,
        model: String,
        previousResponseID: String?,
        toolContext: OpenCodeGoToolContext = OpenCodeGoToolContext()
    ) {
        self.body = body
        self.model = model
        self.previousResponseID = previousResponseID
        self.toolContext = toolContext
    }
}

/// The Responses SSE sequence generated from a complete Chat Completions body.
public struct OpenCodeGoResponsesConversion: Sendable {
    public let responseID: String
    public let sse: Data
    public let toolCalls: [OpenCodeGoToolCall]
    public let reasoningContent: String?

    public init(
        responseID: String,
        sse: Data,
        toolCalls: [OpenCodeGoToolCall],
        reasoningContent: String? = nil
    ) {
        self.responseID = responseID
        self.sse = sse
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
    }
}

/// Injectable transport boundary for the upstream Chat Completions request.
public struct OpenCodeGoBridgeTransportResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol OpenCodeGoBridgeTransport: AnyObject, Sendable {
    func execute(_ request: URLRequest) async throws -> OpenCodeGoBridgeTransportResponse
}
