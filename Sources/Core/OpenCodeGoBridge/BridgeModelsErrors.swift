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
    case sessionRequestLimitReached
    case upstreamUnavailable
    case upstreamRejected
    case invalidUpstreamResponse

    public var errorDescription: String? {
        switch self {
        case .portInUse:
            return L10n.tr("The OpenCode Go bridge port 14556 is already in use.")
        case .unableToStart:
            return L10n.tr("The OpenCode Go bridge could not start.")
        case .requestTooLarge:
            return L10n.tr("The bridge request exceeds the supported size limit.")
        case .contentLengthRequired:
            return L10n.tr("The bridge requires a Content-Length request body.")
        case .invalidContentLength:
            return L10n.tr("The bridge received an invalid Content-Length header.")
        case .unsupportedContentEncoding:
            return L10n.tr("The bridge does not support this request content encoding.")
        case .invalidRequest:
            return L10n.tr("The bridge received an unsupported Responses request.")
        case .unsupportedModel:
            return L10n.tr("The bridge supports only known OpenCode Go Chat Completions models.")
        case .missingAuthorization:
            return L10n.tr("The bridge request did not include provider authorization.")
        case .missingProviderCredential:
            return L10n.tr("The bridge has no active provider credential.")
        case .sessionRequestLimitReached:
            return L10n.tr("The bridge has reached its active session request limit.")
        case .upstreamUnavailable:
            return L10n.tr("OpenCode Go is temporarily unavailable.")
        case .upstreamRejected:
            return L10n.tr("OpenCode Go rejected the request.")
        case .invalidUpstreamResponse:
            return L10n.tr("OpenCode Go returned an unsupported Chat Completions response.")
        }
    }
}

/// A narrowly scoped provider-lane state that can be diagnosed without
/// retaining or exposing an upstream response body.
public enum OpenCodeGoProviderStatusCategory: String, Codable, Equatable, Sendable {
    case deepSeekV4FlashLaneUnavailable = "deepseek_v4_flash_lane_unavailable"
}

/// A sanitized error suitable for a local HTTP response or Responses SSE event.
public struct OpenCodeGoNormalizedError: Equatable, Sendable {
    public let statusCode: Int
    public let code: String
    public let message: String
    public let providerStatus: OpenCodeGoProviderStatusCategory?

    public init(
        statusCode: Int,
        code: String,
        message: String,
        providerStatus: OpenCodeGoProviderStatusCategory? = nil
    ) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
        self.providerStatus = providerStatus
    }
}

/// Maps bridge and URLSession failures without exposing raw provider output.
public enum OpenCodeGoBridgeErrorNormalizer {
    public static func normalize(
        _ error: Error,
        upstreamStatusCode: Int? = nil,
        upstreamErrorBody: Data? = nil,
        model: String? = nil
    ) -> OpenCodeGoNormalizedError {
        if let upstreamStatusCode {
            if let providerStatus = providerStatus(
                for: model,
                upstreamStatusCode: upstreamStatusCode
            ) {
                return normalizedProviderStatus(providerStatus)
            }
            switch upstreamStatusCode {
            case 400:
                return normalizedInvalidUpstreamRequest(from: upstreamErrorBody)
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
        case .sessionRequestLimitReached:
            return OpenCodeGoNormalizedError(
                statusCode: 503,
                code: "bridge_session_request_limit",
                message: "The bridge has reached its active session request limit."
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

    /// Reads only the standard JSON error fields needed for a fixed,
    /// non-sensitive classification. The upstream response itself is never
    /// retained or reflected into an error returned to Codex.
    private static func normalizedInvalidUpstreamRequest(
        from upstreamErrorBody: Data?
    ) -> OpenCodeGoNormalizedError {
        guard let fields = upstreamErrorFields(from: upstreamErrorBody) else {
            // The category and status are fixed allowlisted text. The opaque
            // body, including malformed JSON and oversized payloads, is never
            // copied into logs, metrics, or the response to Codex.
            return OpenCodeGoNormalizedError(
                statusCode: 400,
                code: "upstream_invalid_request_opaque_http_400",
                message: "OpenCode Go rejected the converted request (HTTP 400; upstream detail unavailable)."
            )
        }
        if matchesReasoningContentRequirement(fields) {
            return OpenCodeGoNormalizedError(
                statusCode: 400,
                code: "upstream_reasoning_content_required",
                message: "OpenCode Go requires reasoning content for this request."
            )
        }
        if matchesUnsupportedParameterOrToolSchema(fields) {
            return OpenCodeGoNormalizedError(
                statusCode: 400,
                code: "upstream_unsupported_parameter_or_tool_schema",
                message: "OpenCode Go rejected an unsupported parameter or tool schema."
            )
        }
        if matchesDeepSeekThinkingToolChoice(fields) {
            return OpenCodeGoNormalizedError(
                statusCode: 400,
                code: "upstream_thinking_tool_choice_unsupported",
                message: "OpenCode Go DeepSeek thinking mode rejected this tool_choice."
            )
        }
        if matchesResponseFormatRequirement(fields) {
            return OpenCodeGoNormalizedError(
                statusCode: 400,
                code: "upstream_response_format_unsupported",
                message: "OpenCode Go rejected response_format for this request."
            )
        }
        return OpenCodeGoNormalizedError(
            statusCode: 400,
            code: "upstream_invalid_request",
            message: "OpenCode Go rejected the converted request."
        )
    }

    /// Public OpenCode reports show a model-specific service lane failure for
    /// DeepSeek V4 Flash. Restrict this classification to 5xx statuses: a 400
    /// still has a plausible request-shape cause and a 403 may be a genuine
    /// entitlement failure, so neither is relabeled as a provider outage.
    private static func providerStatus(
        for model: String?,
        upstreamStatusCode: Int
    ) -> OpenCodeGoProviderStatusCategory? {
        guard
            let model,
            (500...599).contains(upstreamStatusCode),
            model.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("deepseek-v4-flash") == .orderedSame
        else {
            return nil
        }
        return .deepSeekV4FlashLaneUnavailable
    }

    private static func normalizedProviderStatus(
        _ providerStatus: OpenCodeGoProviderStatusCategory
    ) -> OpenCodeGoNormalizedError {
        switch providerStatus {
        case .deepSeekV4FlashLaneUnavailable:
            return OpenCodeGoNormalizedError(
                statusCode: 502,
                code: "upstream_deepseek_v4_flash_lane_unavailable",
                message: "The OpenCode Go DeepSeek V4 Flash lane is temporarily unavailable.",
                providerStatus: providerStatus
            )
        }
    }

    private static func upstreamErrorFields(
        from upstreamErrorBody: Data?
    ) -> OpenCodeGoUpstreamErrorFields? {
        // A bounded parse prevents an error payload from becoming a memory
        // amplification path. The fields are used only for classification.
        guard
            let upstreamErrorBody,
            upstreamErrorBody.count <= 64 * 1024,
            let object = try? JSONSerialization.jsonObject(with: upstreamErrorBody),
            let root = object as? [String: Any],
            let error = root["error"] as? [String: Any]
        else {
            return nil
        }
        return OpenCodeGoUpstreamErrorFields(
            message: error["message"] as? String,
            type: error["type"] as? String,
            code: error["code"] as? String,
            param: error["param"] as? String
        )
    }

    private static func matchesReasoningContentRequirement(
        _ fields: OpenCodeGoUpstreamErrorFields?
    ) -> Bool {
        let values = fields?.normalizedValues ?? []
        let mentionsReasoningContent = values.contains {
            $0.contains("reasoning_content") || $0.contains("reasoning content")
        }
        let requirementMarkers = [
            "required",
            "missing",
            "must include",
            "must be included",
            "must provide",
            "must be provided",
            "not provided"
        ]
        return mentionsReasoningContent && values.contains { value in
            requirementMarkers.contains { value.contains($0) }
        }
    }

    private static func matchesUnsupportedParameterOrToolSchema(
        _ fields: OpenCodeGoUpstreamErrorFields?
    ) -> Bool {
        let values = fields?.normalizedValues ?? []
        let unsupportedMarkers = [
            "unsupported parameter",
            "unknown parameter",
            "unrecognized parameter",
            "invalid parameter",
            "unknown field",
            "unrecognized field",
            "additional property",
            "unsupported tool",
            "tool schema",
            "function schema",
            "invalid schema",
            "schema validation",
            "unsupported_parameter",
            "unsupported_tool",
            "invalid_tool_schema"
        ]
        guard values.contains(where: { value in
            unsupportedMarkers.contains { value.contains($0) }
        }) else {
            return false
        }

        // The marker alone is sufficient for an explicit unsupported
        // parameter or schema error. `param` remains useful for providers
        // that put the tool field there and a shorter marker in `code`.
        return true
    }

    private static func matchesDeepSeekThinkingToolChoice(
        _ fields: OpenCodeGoUpstreamErrorFields?
    ) -> Bool {
        let values = fields?.normalizedValues ?? []
        return values.contains {
            $0.contains("thinking mode does not support this tool_choice")
                || ($0.contains("thinking") && $0.contains("tool_choice"))
        }
    }

    private static func matchesResponseFormatRequirement(
        _ fields: OpenCodeGoUpstreamErrorFields?
    ) -> Bool {
        let values = fields?.normalizedValues ?? []
        return values.contains {
            $0.contains("response_format") || $0.contains("json_object")
        }
    }
}

private struct OpenCodeGoUpstreamErrorFields {
    let message: String?
    let type: String?
    let code: String?
    let param: String?

    var normalizedValues: [String] {
        [message, type, code, param].compactMap {
            $0?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }.filter { !$0.isEmpty }
    }
}

/// Serializes only requests that identify the same Codex session. A slot is
/// discarded as soon as its active request and waiters finish, so the
/// coordinator never retains request bodies, credentials, or idle sessions.
public actor OpenCodeGoSessionRequestCoordinator {
    private struct Slot {
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let capacity: Int
    private let maximumWaitersPerSession: Int
    private let maximumSessionKeyLength: Int
    private var slots: [String: Slot] = [:]

    /// `capacity` bounds simultaneously tracked active session keys. Requests
    /// for an admitted session always preserve their ordering. Requests above
    /// either bound are rejected by `perform(for:operation:)` rather than
    /// retaining an unbounded backlog.
    public init(
        capacity: Int = 128,
        maximumWaitersPerSession: Int = 64,
        maximumSessionKeyLength: Int = 256
    ) {
        self.capacity = max(1, capacity)
        self.maximumWaitersPerSession = max(1, maximumWaitersPerSession)
        self.maximumSessionKeyLength = max(16, maximumSessionKeyLength)
    }

    /// Runs the operation in a serial slot for a non-empty session key. A
    /// missing or oversized key intentionally receives no shared slot so each
    /// otherwise-unidentified request remains independent. Returns `false`
    /// only when the bounded active-session or per-session queue limit is hit.
    public func perform(
        for sessionKey: String?,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        guard let key = normalizedSessionKey(sessionKey) else {
            await operation()
            return true
        }
        guard await acquire(key) else {
            return false
        }
        await operation()
        release(key)
        return true
    }

    /// Test-only visibility through `@testable`; the count never includes
    /// completed sessions because their slots are removed in `release(_:)`.
    func queuedRequestCount(for sessionKey: String) -> Int {
        guard let key = normalizedSessionKey(sessionKey) else {
            return 0
        }
        return slots[key]?.waiters.count ?? 0
    }

    func trackedSessionCount() -> Int {
        slots.count
    }

    private func acquire(_ key: String) async -> Bool {
        if var slot = slots[key] {
            guard slot.waiters.count < maximumWaitersPerSession else {
                return false
            }
            await withCheckedContinuation { continuation in
                slot.waiters.append(continuation)
                slots[key] = slot
            }
            return true
        }

        guard slots.count < capacity else {
            return false
        }
        slots[key] = Slot()
        return true
    }

    private func release(_ key: String) {
        guard var slot = slots[key] else {
            return
        }
        if !slot.waiters.isEmpty {
            let next = slot.waiters.removeFirst()
            slots[key] = slot
            next.resume()
            return
        }

        slots.removeValue(forKey: key)
    }

    private func normalizedSessionKey(_ sessionKey: String?) -> String? {
        guard let sessionKey else {
            return nil
        }
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !key.isEmpty,
            key.utf8.count <= maximumSessionKeyLength
        else {
            return nil
        }
        return key
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
    /// Distinguishes an absent field from an explicitly empty
    /// `reasoning_content` value required by some thinking models.
    public let reasoningContentPresent: Bool

    public init(
        toolCalls: [OpenCodeGoToolCall],
        reasoningContent: String? = nil,
        reasoningContentPresent: Bool = false
    ) {
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
        self.reasoningContentPresent = reasoningContentPresent || reasoningContent != nil
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
        reasoningContent: String? = nil,
        reasoningContentPresent: Bool = false
    ) {
        guard !responseID.isEmpty, !toolCalls.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        insertionOrder.removeAll { $0 == responseID }
        entries[responseID] = OpenCodeGoToolCallHistory(
            toolCalls: toolCalls,
            reasoningContent: reasoningContent,
            reasoningContentPresent: reasoningContentPresent
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

/// Selects the Responses output contract expected by the originating Codex
/// request. Remote compaction v2 still uses `/responses`, but it requires one
/// `compaction` output item instead of an assistant message.
public enum OpenCodeGoResponsesOutputMode: Equatable, Sendable {
    case standard
    case compaction
}

enum OpenCodeGoCompactionEnvelope {
    static let prefix = "all-in-one-codex-chat-summary-v1\n"

    static func wrap(_ summary: String) -> String {
        prefix + summary
    }

    static func unwrap(_ encryptedContent: String) -> String? {
        guard encryptedContent.hasPrefix(prefix) else { return nil }
        return String(encryptedContent.dropFirst(prefix.count))
    }
}

/// The buffered JSON body that the bridge sends to Chat Completions.
public struct OpenCodeGoChatRequestConversion: Sendable {
    public let body: Data
    public let model: String
    public let previousResponseID: String?
    public let toolContext: OpenCodeGoToolContext
    public let outputMode: OpenCodeGoResponsesOutputMode

    public init(
        body: Data,
        model: String,
        previousResponseID: String?,
        toolContext: OpenCodeGoToolContext = OpenCodeGoToolContext(),
        outputMode: OpenCodeGoResponsesOutputMode = .standard
    ) {
        self.body = body
        self.model = model
        self.previousResponseID = previousResponseID
        self.toolContext = toolContext
        self.outputMode = outputMode
    }
}

/// The Responses SSE sequence generated from a complete Chat Completions body.
public struct OpenCodeGoResponsesConversion: Sendable {
    public let responseID: String
    public let sse: Data
    public let toolCalls: [OpenCodeGoToolCall]
    public let reasoningContent: String?
    /// Whether the upstream completion supplied or requires a
    /// `reasoning_content` field, including an explicit empty value.
    public let reasoningContentPresent: Bool

    public init(
        responseID: String,
        sse: Data,
        toolCalls: [OpenCodeGoToolCall],
        reasoningContent: String? = nil,
        reasoningContentPresent: Bool = false
    ) {
        self.responseID = responseID
        self.sse = sse
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
        self.reasoningContentPresent = reasoningContentPresent || reasoningContent != nil
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
