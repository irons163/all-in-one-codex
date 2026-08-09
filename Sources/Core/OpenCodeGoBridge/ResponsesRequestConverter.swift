import Foundation

/// Pure conversion from the Codex Responses request shape to OpenAI-compatible
/// Chat Completions JSON. No credentials are accepted or retained here.
public enum OpenCodeGoResponsesRequestConverter {
    public static func convert(
        responseRequest: Data,
        toolCallCache: OpenCodeGoToolCallCache? = nil
    ) throws -> OpenCodeGoChatRequestConversion {
        guard let root = try JSONSerialization.jsonObject(with: responseRequest) as? [String: Any] else {
            throw OpenCodeGoBridgeError.invalidRequest
        }

        let model = try supportedChatModel(from: root)
        let thinkingProfile = OpenCodeGoThinkingProfile.infer(model: model)
        let requiresThinkingAssistantFields = thinkingProfile?.requiresToolCallReasoningPlaceholder == true
        let stream = (root["stream"] as? Bool) ?? true
        let inputItems = root["input"] as? [[String: Any]]
        let outputMode: OpenCodeGoResponsesOutputMode = inputItems?.contains(where: isCompactionTrigger) == true
            ? .compaction
            : .standard
        // A compaction request asks the model for a continuation summary and
        // must not execute tools. Skipping them also avoids forcing Chat-only
        // providers to understand Responses-only namespace/deferred tools.
        let toolConversion = outputMode == .compaction
            ? ToolConversion(tools: [], context: OpenCodeGoToolContext())
            : try chatTools(from: root["tools"])
        var systemMessages: [[String: Any]] = []
        var conversationMessages: [[String: Any]] = []
        var pendingReasoningContent: String?
        var lastAssistantConversationMessageIndex: Int?

        if let instructions = root["instructions"] as? String, !instructions.isEmpty {
            systemMessages.append(["role": "system", "content": instructions])
        }

        let previousResponseID = root["previous_response_id"] as? String
        let cachedHistory = previousResponseID.flatMap { toolCallCache?.history(for: $0) }
        // Match cc-switch `CodexChatHistoryStore.enrich_request`: restore cached
        // tool calls only for orphan `function_call_output` items. Codex often
        // sends `previous_response_id` together with a full input that already
        // contains the matching function_call items; blindly prepending the
        // cache duplicates assistant tool history and OpenCode Go returns 400.
        let existingCallIDs = Set((inputItems ?? []).flatMap(toolCallIDs(in:)))
        let outputCallIDs = Set((inputItems ?? []).compactMap(toolCallOutputID(in:)))
        let missingOutputCallIDs = outputCallIDs.subtracting(existingCallIDs)
        let restoredToolCalls: [OpenCodeGoToolCall]
        if let cachedHistory, !missingOutputCallIDs.isEmpty {
            restoredToolCalls = cachedHistory.toolCalls.filter { missingOutputCallIDs.contains($0.id) }
        } else {
            restoredToolCalls = []
        }

        if let input = root["input"] as? String {
            conversationMessages.append(["role": "user", "content": input])
        } else if let inputItems {
            // Insert restored calls immediately before the first tool output,
            // matching cc-switch enrich_request ordering.
            let effectiveInputItems: [[String: Any]]
            if let cachedHistory, !restoredToolCalls.isEmpty {
                effectiveInputItems = enrichInputItems(
                    inputItems,
                    withRestoredToolCalls: restoredToolCalls,
                    reasoningContent: cachedHistory.reasoningContent,
                    reasoningContentPresent: cachedHistory.reasoningContentPresent
                )
            } else {
                effectiveInputItems = inputItems
            }

            var pendingToolCalls: [OpenCodeGoToolCall] = []
            for inputItem in effectiveInputItems {
                try appendChatMessages(
                    from: inputItem,
                    systemMessages: &systemMessages,
                    conversationMessages: &conversationMessages,
                    toolContext: toolConversion.context,
                    requiresThinkingAssistantFields: requiresThinkingAssistantFields,
                    pendingReasoningContent: &pendingReasoningContent,
                    pendingToolCalls: &pendingToolCalls,
                    lastAssistantConversationMessageIndex: &lastAssistantConversationMessageIndex
                )
            }
            flushPendingToolCalls(
                &pendingToolCalls,
                pendingReasoningContent: &pendingReasoningContent,
                conversationMessages: &conversationMessages,
                lastAssistantConversationMessageIndex: &lastAssistantConversationMessageIndex,
                requiresThinkingAssistantFields: requiresThinkingAssistantFields
            )
            attachPendingReasoning(
                &pendingReasoningContent,
                to: &conversationMessages,
                lastAssistantConversationMessageIndex: lastAssistantConversationMessageIndex
            )
            let stillMissing = missingOutputCallIDs.subtracting(Set(restoredToolCalls.map(\.id)))
            if !stillMissing.isEmpty {
                throw OpenCodeGoBridgeError.invalidRequest
            }
        } else if root["input"] != nil {
            throw OpenCodeGoBridgeError.invalidRequest
        }

        if requiresThinkingAssistantFields {
            // Match cc-switch: thinking models reject assistant tool-call history
            // that omits reasoning_content or only carries an empty string.
            backfillThinkingToolCallReasoningPlaceholders(&conversationMessages)
        }

        var chatRequest: [String: Any] = [
            "model": model,
            "messages": systemMessages + conversationMessages,
            "stream": stream
        ]

        if !toolConversion.tools.isEmpty {
            chatRequest["tools"] = toolConversion.tools
            let toolChoice = try chatToolChoice(
                from: root["tool_choice"],
                toolContext: toolConversion.context
            )
            if let toolChoice {
                chatRequest["tool_choice"] = toolChoice.value
            }
            if toolChoice?.forcesSingleTool == true {
                chatRequest["parallel_tool_calls"] = false
            } else if let parallel = root["parallel_tool_calls"] as? Bool {
                chatRequest["parallel_tool_calls"] = parallel
            }
        }

        if let maximum = root["max_output_tokens"]
            ?? root["max_completion_tokens"]
            ?? root["max_tokens"]
        {
            chatRequest["max_tokens"] = maximum
        }
        if stream {
            chatRequest["stream_options"] = ["include_usage": true]
        }
        for key in ["temperature", "top_p", "seed"] {
            if let value = root[key] {
                chatRequest[key] = value
            }
        }

        applyThinkingControls(
            profile: thinkingProfile,
            root: root,
            to: &chatRequest
        )

        guard JSONSerialization.isValidJSONObject(chatRequest) else {
            throw OpenCodeGoBridgeError.invalidRequest
        }
        return OpenCodeGoChatRequestConversion(
            body: try JSONSerialization.data(withJSONObject: chatRequest, options: [.sortedKeys]),
            model: model,
            previousResponseID: previousResponseID,
            toolContext: toolConversion.context,
            outputMode: outputMode
        )
    }

    private static func supportedChatModel(from root: [String: Any]) throws -> String {
        guard let rawModel = root["model"] as? String else {
            throw OpenCodeGoBridgeError.invalidRequest
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw OpenCodeGoBridgeError.invalidRequest
        }
        guard
            let descriptor = ProviderCatalog.descriptor(for: model, presetID: .openCodeGo),
            descriptor.wireAPI == .chatCompletions
        else {
            throw OpenCodeGoBridgeError.unsupportedModel
        }
        return model
    }

    private static func applyThinkingControls(
        profile: OpenCodeGoThinkingProfile?,
        root: [String: Any],
        to chatRequest: inout [String: Any]
    ) {
        guard let profile, profile.supportsThinking else {
            if let responseFormat = root["response_format"] {
                chatRequest["response_format"] = responseFormat
            }
            return
        }

        if profile.rejectsJSONObjectResponseFormat {
            // Live OpenCode Go DeepSeek probes: json_object without "json" in the
            // prompt returns HTTP 400. Do not forward response_format.
        } else if let responseFormat = root["response_format"] {
            chatRequest["response_format"] = responseFormat
        }

        guard let thinking = thinkingToggle(from: root, profile: profile) else {
            return
        }

        switch profile.thinkingParam {
        case .thinking:
            chatRequest["thinking"] = thinking
        case .enableThinking:
            chatRequest["enable_thinking"] = thinking["type"] == "enabled"
        case .none:
            break
        }

        if thinking["type"] == "enabled",
           profile.rejectsForcedToolChoiceWhileThinking
        {
            sanitizeThinkingToolChoice(&chatRequest)
        }
    }

    private static func thinkingToggle(
        from root: [String: Any],
        profile: OpenCodeGoThinkingProfile
    ) -> [String: String]? {
        guard profile.thinkingParam != .none else {
            return nil
        }
        guard let effort = reasoningEffort(from: root) else {
            // Thinking models default to enabled when Codex omits effort.
            return ["type": "enabled"]
        }
        let type = ["none", "off", "disabled"].contains(effort) ? "disabled" : "enabled"
        return ["type": type]
    }

    /// DeepSeek V4 thinking mode only accepts `tool_choice` of `auto` or `none`.
    /// Forced function / `required` choices must be relaxed to `auto`.
    private static func sanitizeThinkingToolChoice(
        _ chatRequest: inout [String: Any]
    ) {
        guard let toolChoice = chatRequest["tool_choice"] else {
            return
        }
        if let named = toolChoice as? String {
            guard named == "required" else {
                return
            }
            chatRequest["tool_choice"] = "auto"
            chatRequest.removeValue(forKey: "parallel_tool_calls")
            return
        }
        if toolChoice is [String: Any] {
            chatRequest["tool_choice"] = "auto"
            chatRequest.removeValue(forKey: "parallel_tool_calls")
        }
    }

    private static func reasoningEffort(from root: [String: Any]) -> String? {
        if let reasoning = root["reasoning"] as? [String: Any],
           let effort = trimmedString(reasoning["effort"])
        {
            return effort.lowercased()
        }
        return trimmedString(root["reasoning_effort"])?.lowercased()
    }

    private static func appendChatMessages(
        from inputItem: [String: Any],
        systemMessages: inout [[String: Any]],
        conversationMessages: inout [[String: Any]],
        toolContext: OpenCodeGoToolContext,
        requiresThinkingAssistantFields: Bool,
        pendingReasoningContent: inout String?,
        pendingToolCalls: inout [OpenCodeGoToolCall],
        lastAssistantConversationMessageIndex: inout Int?
    ) throws {
        let type = inputItem["type"] as? String
        if type == "reasoning" {
            appendPendingReasoning(
                reasoningContent(from: inputItem),
                to: &pendingReasoningContent
            )
            return
        }

        if type == "compaction_trigger" {
            flushPendingToolCalls(
                &pendingToolCalls,
                pendingReasoningContent: &pendingReasoningContent,
                conversationMessages: &conversationMessages,
                lastAssistantConversationMessageIndex: &lastAssistantConversationMessageIndex,
                requiresThinkingAssistantFields: requiresThinkingAssistantFields
            )
            conversationMessages.append([
                "role": "user",
                "content": """
                Create a compact, self-contained continuation summary of the conversation above. \
                Preserve the user's goals, decisions, constraints, completed work, current state, \
                relevant file paths and identifiers, unresolved problems, and the exact next steps. \
                Return only the summary text; do not call tools.
                """
            ])
            return
        }

        if type == "compaction",
           let encryptedContent = stringValue(inputItem["encrypted_content"]),
           let summary = OpenCodeGoCompactionEnvelope.unwrap(encryptedContent),
           !summary.isEmpty
        {
            flushPendingToolCalls(
                &pendingToolCalls,
                pendingReasoningContent: &pendingReasoningContent,
                conversationMessages: &conversationMessages,
                lastAssistantConversationMessageIndex: &lastAssistantConversationMessageIndex,
                requiresThinkingAssistantFields: requiresThinkingAssistantFields
            )
            conversationMessages.append([
                "role": "system",
                "content": "Prior compacted conversation context:\n\(summary)"
            ])
            return
        }

        if isToolCallOutput(inputItem) {
            flushPendingToolCalls(
                &pendingToolCalls,
                pendingReasoningContent: &pendingReasoningContent,
                conversationMessages: &conversationMessages,
                lastAssistantConversationMessageIndex: &lastAssistantConversationMessageIndex,
                requiresThinkingAssistantFields: requiresThinkingAssistantFields
            )
            guard let callID = stringValue(inputItem["call_id"] ?? inputItem["tool_call_id"]),
                  !callID.isEmpty
            else {
                throw OpenCodeGoBridgeError.invalidRequest
            }
            conversationMessages.append([
                "role": "tool",
                "tool_call_id": callID,
                "content": toolOutputString(from: inputItem["output"])
            ])
            return
        }

        if type == "function_call" || type == "custom_tool_call" {
            guard let toolCall = toolCall(from: inputItem, toolContext: toolContext, kind: type) else {
                throw OpenCodeGoBridgeError.invalidRequest
            }
            // Match cc-switch: accumulate consecutive function/custom calls into
            // one assistant message so parallel tool turns stay valid for
            // DeepSeek / OpenCode Go thinking models.
            let itemReasoning = inputReasoningContent(from: inputItem)
            if itemReasoning.isPresent {
                appendPendingReasoning(itemReasoning.content, to: &pendingReasoningContent)
            }
            pendingToolCalls.append(toolCall)
            return
        }

        flushPendingToolCalls(
            &pendingToolCalls,
            pendingReasoningContent: &pendingReasoningContent,
            conversationMessages: &conversationMessages,
            lastAssistantConversationMessageIndex: &lastAssistantConversationMessageIndex,
            requiresThinkingAssistantFields: requiresThinkingAssistantFields
        )

        let sourceRole = (inputItem["role"] as? String) ?? "user"
        guard ["system", "developer", "user", "assistant", "tool"].contains(sourceRole) else {
            throw OpenCodeGoBridgeError.invalidRequest
        }
        let role = sourceRole == "developer" || sourceRole == "system" ? "system" : sourceRole
        if role != "assistant" {
            attachPendingReasoning(
                &pendingReasoningContent,
                to: &conversationMessages,
                lastAssistantConversationMessageIndex: lastAssistantConversationMessageIndex
            )
        }
        let convertedContent = chatContent(from: inputItem["content"], toolContext: toolContext)
        var message: [String: Any] = ["role": role]
        if let content = convertedContent.content {
            message["content"] = content
        } else if role != "assistant" || requiresThinkingAssistantFields {
            message["content"] = ""
        }
        if role == "assistant", !convertedContent.toolCalls.isEmpty {
            message["tool_calls"] = convertedContent.toolCalls.map(chatToolCallObject)
        }
        if role == "assistant" {
            let topLevelReasoning = inputReasoningContent(from: inputItem)
            let sourceReasoning = topLevelReasoning.isPresent
                ? topLevelReasoning
                : (
                    content: convertedContent.reasoningContent,
                    isPresent: convertedContent.reasoningContentPresent
                )
            let reasoning = consumePendingReasoning(
                sourceReasoning,
                pendingReasoningContent: &pendingReasoningContent
            )
            let hasToolCalls = !convertedContent.toolCalls.isEmpty
            if let text = reasoning.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message["reasoning_content"] = text
            } else if reasoning.isPresent, !requiresThinkingAssistantFields {
                // Preserve explicit empty for non-thinking providers.
                message["reasoning_content"] = reasoning.content ?? ""
            } else if requiresThinkingAssistantFields, hasToolCalls {
                // Filled by backfillThinkingToolCallReasoningPlaceholders.
                message["reasoning_content"] = thinkingToolCallReasoningPlaceholder
            }
            // Thinking non-tool assistants: omit empty reasoning_content.
            // Official docs only require it on tool-call turns.
        }
        if role == "tool" {
            guard let callID = stringValue(inputItem["call_id"] ?? inputItem["tool_call_id"]) else {
                throw OpenCodeGoBridgeError.invalidRequest
            }
            message["tool_call_id"] = callID
        }

        if role == "system" {
            systemMessages.append(message)
            lastAssistantConversationMessageIndex = nil
        } else {
            conversationMessages.append(message)
            if role == "assistant" {
                lastAssistantConversationMessageIndex = conversationMessages.indices.last
            } else if role != "tool" {
                lastAssistantConversationMessageIndex = nil
            }
        }
    }

    /// Inserts restored Responses function_call items before the first tool
    /// output, mirroring cc-switch `CodexChatHistoryStore.enrich_request`.
    private static func enrichInputItems(
        _ inputItems: [[String: Any]],
        withRestoredToolCalls restoredToolCalls: [OpenCodeGoToolCall],
        reasoningContent: String?,
        reasoningContentPresent: Bool
    ) -> [[String: Any]] {
        guard !restoredToolCalls.isEmpty else {
            return inputItems
        }
        var enriched: [[String: Any]] = []
        var inserted = false
        for item in inputItems {
            if !inserted, isToolCallOutput(item) {
                for (index, toolCall) in restoredToolCalls.enumerated() {
                    var synthetic: [String: Any] = [
                        "type": "function_call",
                        "call_id": toolCall.id,
                        "name": toolCall.name,
                        "arguments": toolCall.arguments
                    ]
                    if index == 0, reasoningContentPresent || reasoningContent != nil {
                        synthetic["reasoning_content"] = reasoningContent ?? ""
                    }
                    enriched.append(synthetic)
                }
                inserted = true
            }
            enriched.append(item)
        }
        return enriched
    }

    private static func flushPendingToolCalls(
        _ pendingToolCalls: inout [OpenCodeGoToolCall],
        pendingReasoningContent: inout String?,
        conversationMessages: inout [[String: Any]],
        lastAssistantConversationMessageIndex: inout Int?,
        requiresThinkingAssistantFields: Bool
    ) {
        guard !pendingToolCalls.isEmpty else {
            return
        }
        let reasoningText = pendingReasoningContent
        pendingReasoningContent = nil
        conversationMessages.append(
            assistantToolCallMessage(
                pendingToolCalls,
                reasoningContent: reasoningText,
                reasoningContentPresent: reasoningText != nil,
                requiresThinkingAssistantFields: requiresThinkingAssistantFields
            )
        )
        pendingToolCalls.removeAll(keepingCapacity: true)
        lastAssistantConversationMessageIndex = conversationMessages.indices.last
    }

    private static func chatContent(
        from rawContent: Any?,
        toolContext: OpenCodeGoToolContext
    ) -> (
        content: Any?,
        toolCalls: [OpenCodeGoToolCall],
        reasoningContent: String?,
        reasoningContentPresent: Bool
    ) {
        guard let rawContent else {
            return (nil, [], nil, false)
        }
        if let content = rawContent as? String {
            return (content, [], nil, false)
        }
        guard let parts = rawContent as? [[String: Any]] else {
            return (stringValue(rawContent), [], nil, false)
        }

        var convertedParts: [[String: Any]] = []
        var toolCalls: [OpenCodeGoToolCall] = []
        var reasoningParts: [String] = []
        var reasoningContentPresent = false
        for part in parts {
            let type = part["type"] as? String
            if (type == "function_call" || type == "custom_tool_call"),
               let toolCall = toolCall(from: part, toolContext: toolContext, kind: type)
            {
                toolCalls.append(toolCall)
                continue
            }
            if isReasoningContentPart(type) {
                reasoningContentPresent = true
                reasoningParts.append(reasoningContent(from: part) ?? "")
                continue
            }
            switch type {
            case "input_text", "output_text", "text":
                if let text = stringValue(part["text"]) {
                    convertedParts.append(["type": "text", "text": text])
                }
            case "input_image", "image_url", "image":
                if let imageURL = normalizedImageURL(from: part["image_url"]) {
                    convertedParts.append(["type": "image_url", "image_url": imageURL])
                } else if let url = stringValue(part["url"]) {
                    convertedParts.append(["type": "image_url", "image_url": ["url": url]])
                }
            case "input_file", "file":
                var file: [String: Any] = [:]
                for key in ["file_id", "filename", "file_data"] {
                    if let value = part[key] { file[key] = value }
                }
                if !file.isEmpty { convertedParts.append(["type": "file", "file": file]) }
            case "input_audio", "audio":
                if let audio = part["input_audio"] ?? part["audio"] {
                    convertedParts.append(["type": "input_audio", "input_audio": audio])
                }
            default:
                if let text = stringValue(part["text"]) {
                    convertedParts.append(["type": "text", "text": text])
                }
            }
        }
        return (
            convertedParts.isEmpty ? nil : convertedParts,
            toolCalls,
            reasoningContentPresent ? reasoningParts.joined() : nil,
            reasoningContentPresent
        )
    }

    private static func isReasoningContentPart(_ type: String?) -> Bool {
        guard let type = type?.lowercased() else {
            return false
        }
        return type == "thinking" || type == "reasoning" || type.hasPrefix("reasoning_")
    }

    /// A Responses history can carry reasoning as a structured content part.
    /// Chat Completions accepts it only as a string field, so prefer textual
    /// fields and losslessly serialize unfamiliar structures as a fallback.
    private static func reasoningContent(from part: [String: Any]) -> String? {
        for key in [
            "reasoning_content",
            "reasoning",
            "reasoning_text",
            "text",
            "content",
            "value",
            "summary"
        ] {
            if let value = part[key], let reasoning = serializedReasoningContent(value) {
                return reasoning
            }
        }
        return stringValue(part)
    }

    private static func serializedReasoningContent(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let parts = value as? [[String: Any]] {
            let textParts = parts.compactMap {
                stringValue(
                    $0["reasoning_content"]
                        ?? $0["reasoning"]
                        ?? $0["reasoning_text"]
                        ?? $0["text"]
                        ?? $0["content"]
                        ?? $0["value"]
                )
            }
            if !textParts.isEmpty {
                return textParts.joined()
            }
        }
        return stringValue(value)
    }

    /// A Responses reasoning item often arrives immediately before the
    /// assistant tool-call item it explains. Chat Completions has no standalone
    /// reasoning message role, so retain it until it can be replayed as
    /// `reasoning_content` on that assistant message.
    private static func appendPendingReasoning(
        _ content: String?,
        to pendingReasoningContent: inout String?
    ) {
        guard let content, !content.isEmpty else {
            return
        }
        guard let existing = pendingReasoningContent, !existing.isEmpty else {
            pendingReasoningContent = content
            return
        }
        guard !existing.contains(content) else {
            return
        }
        pendingReasoningContent = "\(existing)\n\n\(content)"
    }

    private static func consumePendingReasoning(
        _ directReasoning: (content: String?, isPresent: Bool),
        pendingReasoningContent: inout String?
    ) -> (content: String?, isPresent: Bool) {
        guard let pending = pendingReasoningContent, !pending.isEmpty else {
            return directReasoning
        }
        pendingReasoningContent = nil
        guard directReasoning.isPresent,
              let direct = directReasoning.content,
              !direct.isEmpty
        else {
            return (pending, true)
        }
        guard !direct.contains(pending) else {
            return directReasoning
        }
        return ("\(pending)\n\n\(direct)", true)
    }

    private static func attachPendingReasoning(
        _ pendingReasoningContent: inout String?,
        to conversationMessages: inout [[String: Any]],
        lastAssistantConversationMessageIndex: Int?
    ) {
        guard let pending = pendingReasoningContent, !pending.isEmpty else {
            return
        }
        defer { pendingReasoningContent = nil }
        guard
            let index = lastAssistantConversationMessageIndex,
            conversationMessages.indices.contains(index),
            conversationMessages[index]["role"] as? String == "assistant"
        else {
            return
        }
        guard let existing = conversationMessages[index]["reasoning_content"] as? String,
              !existing.isEmpty
        else {
            conversationMessages[index]["reasoning_content"] = pending
            return
        }
        guard !existing.contains(pending) else {
            return
        }
        conversationMessages[index]["reasoning_content"] = "\(existing)\n\n\(pending)"
    }

    private static func normalizedImageURL(from value: Any?) -> [String: Any]? {
        if let url = value as? String { return ["url": url] }
        return value as? [String: Any]
    }

    private struct ToolConversion {
        let tools: [[String: Any]]
        let context: OpenCodeGoToolContext
    }

    private static func chatTools(from rawTools: Any?) throws -> ToolConversion {
        guard let rawTools else {
            return ToolConversion(tools: [], context: OpenCodeGoToolContext())
        }
        guard let rawResponseTools = rawTools as? [[String: Any]] else {
            throw OpenCodeGoBridgeError.invalidRequest
        }
        let responseTools = try flattenedResponseTools(rawResponseTools)

        var tools: [[String: Any]] = []
        var mappings: [OpenCodeGoToolMapping] = []
        var usedNames = Set<String>()
        for (index, responseTool) in responseTools.enumerated() {
            guard let rawType = responseTool["type"] as? String else {
                throw OpenCodeGoBridgeError.invalidRequest
            }
            let namespace = trimmedString(responseTool["namespace"])
            let description = trimmedString(responseTool["description"])
            let kind: OpenCodeGoResponsesToolKind
            let responseName: String
            var function: [String: Any]

            switch rawType {
            case "function":
                kind = .function
                if let nested = responseTool["function"] as? [String: Any] {
                    function = nested
                    if function["name"] == nil { function["name"] = responseTool["name"] }
                } else {
                    function = [:]
                    for key in ["name", "description", "parameters", "strict"] {
                        if let value = responseTool[key] { function[key] = value }
                    }
                }
                guard let name = trimmedString(function["name"]) else {
                    throw OpenCodeGoBridgeError.invalidRequest
                }
                responseName = name
                function["parameters"] = try normalizedFunctionParameters(function["parameters"])

            case "custom":
                kind = .custom
                guard let name = trimmedString(responseTool["name"]) else {
                    throw OpenCodeGoBridgeError.invalidRequest
                }
                if let parameters = responseTool["parameters"],
                   !(parameters is NSNull),
                   !(parameters is [String: Any])
                {
                    throw OpenCodeGoBridgeError.invalidRequest
                }
                responseName = name
                function = [
                    "name": name,
                    "parameters": customInputSchema()
                ]
                if let description { function["description"] = description }

            case "tool_search":
                kind = .toolSearch
                responseName = trimmedString(responseTool["name"])
                    ?? trimmedString(responseTool["namespace"]).map { "\($0)_search" }
                    ?? "tool_search_\(index + 1)"
                function = [
                    "name": responseName,
                    "description": description ?? "Synthetic function for Responses tool_search.",
                    "parameters": customInputSchema()
                ]

            case "web_search":
                // This is a provider-hosted Responses tool. A Chat Completions-only
                // upstream cannot execute it, so omit it instead of presenting it as
                // a function that the bridge could never dispatch.
                continue

            default:
                throw OpenCodeGoBridgeError.invalidRequest
            }

            let chatName = makeChatName(
                responseName: responseName,
                namespace: namespace,
                usedNames: &usedNames
            )
            function["name"] = chatName
            if function["description"] == nil, let description {
                function["description"] = description
            }
            tools.append(["type": "function", "function": function])
            mappings.append(
                OpenCodeGoToolMapping(
                    chatName: chatName,
                    responseName: responseName,
                    kind: kind,
                    namespace: namespace,
                    description: description
                )
            )
        }
        return ToolConversion(tools: tools, context: OpenCodeGoToolContext(mappings: mappings))
    }

    private static func flattenedResponseTools(
        _ responseTools: [[String: Any]]
    ) throws -> [[String: Any]] {
        var flattened: [[String: Any]] = []

        func append(_ tool: [String: Any], inheritedNamespace: String?) throws {
            guard let type = tool["type"] as? String else {
                throw OpenCodeGoBridgeError.invalidRequest
            }
            guard type == "namespace" else {
                var leaf = tool
                if leaf["namespace"] == nil, let inheritedNamespace {
                    leaf["namespace"] = inheritedNamespace
                }
                flattened.append(leaf)
                return
            }

            guard let name = trimmedString(tool["name"]),
                  let children = tool["tools"] as? [[String: Any]]
            else {
                throw OpenCodeGoBridgeError.invalidRequest
            }
            let namespace = inheritedNamespace.map { "\($0)__\(name)" } ?? name
            for child in children {
                try append(child, inheritedNamespace: namespace)
            }
        }

        for tool in responseTools {
            try append(tool, inheritedNamespace: nil)
        }
        return flattened
    }

    /// OpenAI-compatible Chat Completions tool parameters must be an object
    /// schema. Missing and null schemas have an unambiguous empty-object
    /// meaning; malformed non-object schemas are rejected locally rather than
    /// sent upstream as an opaque HTTP 400.
    private static func normalizedFunctionParameters(_ rawParameters: Any?) throws -> [String: Any] {
        guard var parameters = rawParameters as? [String: Any] else {
            if rawParameters == nil || rawParameters is NSNull {
                return ["type": "object", "properties": [String: Any]()]
            }
            throw OpenCodeGoBridgeError.invalidRequest
        }

        if let type = parameters["type"], !(type is NSNull) {
            guard (type as? String)?.lowercased() == "object" else {
                throw OpenCodeGoBridgeError.invalidRequest
            }
        }
        parameters["type"] = "object"

        if parameters["properties"] == nil || parameters["properties"] is NSNull {
            parameters["properties"] = [String: Any]()
        } else if !(parameters["properties"] is [String: Any]) {
            throw OpenCodeGoBridgeError.invalidRequest
        }
        return parameters
    }

    private static func customInputSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": ["input": ["type": "string"]],
            "required": ["input"],
            "additionalProperties": false
        ]
    }

    private static func makeChatName(
        responseName: String,
        namespace: String?,
        usedNames: inout Set<String>
    ) -> String {
        let flattened = namespace.map { "\($0)__\(responseName)" } ?? responseName
        var candidate = chatSafeName(flattened) && flattened.count <= 64
            ? flattened
            : hashedChatName(flattened)
        var collision = 1
        while usedNames.contains(candidate) {
            collision += 1
            candidate = hashedChatName("\(flattened)#\(collision)")
        }
        usedNames.insert(candidate)
        return candidate
    }

    private static func chatSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func hashedChatName(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "tool_\(String(hash, radix: 16))"
    }

    private static func chatToolChoice(
        from rawChoice: Any?,
        toolContext: OpenCodeGoToolContext
    ) throws -> (value: Any, forcesSingleTool: Bool)? {
        guard let rawChoice else { return nil }
        if let choice = rawChoice as? String { return (choice, false) }
        guard let choice = rawChoice as? [String: Any] else {
            throw OpenCodeGoBridgeError.invalidRequest
        }
        if let function = choice["function"] as? [String: Any],
           let rawName = trimmedString(function["name"])
        {
            return ([
                "type": "function",
                "function": ["name": toolContext.chatName(forResponseName: rawName) ?? rawName]
            ], true)
        }
        guard let rawName = trimmedString(choice["name"]) else {
            throw OpenCodeGoBridgeError.invalidRequest
        }
        return ([
            "type": "function",
            "function": ["name": toolContext.chatName(forResponseName: rawName) ?? rawName]
        ], true)
    }

    /// Same placeholder cc-switch injects when a thinking model tool-call turn
    /// has no recoverable reasoning text. Empty string is still rejected.
    private static let thinkingToolCallReasoningPlaceholder = "tool call"

    private static func backfillThinkingToolCallReasoningPlaceholders(
        _ conversationMessages: inout [[String: Any]]
    ) {
        for index in conversationMessages.indices {
            guard conversationMessages[index]["role"] as? String == "assistant",
                  let toolCalls = conversationMessages[index]["tool_calls"] as? [[String: Any]],
                  !toolCalls.isEmpty
            else {
                continue
            }
            let existing = conversationMessages[index]["reasoning_content"] as? String
            let trimmed = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                conversationMessages[index]["reasoning_content"] = thinkingToolCallReasoningPlaceholder
            }
            if conversationMessages[index]["content"] == nil {
                conversationMessages[index]["content"] = ""
            }
        }
    }

    private static func assistantToolCallMessage(
        _ toolCalls: [OpenCodeGoToolCall],
        reasoningContent: String?,
        reasoningContentPresent: Bool = false,
        requiresThinkingAssistantFields: Bool = false
    ) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant"]
        if requiresThinkingAssistantFields {
            message["content"] = ""
        }
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls.map(chatToolCallObject) }
        if reasoningContentPresent || reasoningContent != nil || requiresThinkingAssistantFields {
            let text = reasoningContent ?? ""
            if requiresThinkingAssistantFields,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                message["reasoning_content"] = thinkingToolCallReasoningPlaceholder
            } else {
                message["reasoning_content"] = text
            }
        }
        return message
    }

    private static func inputReasoningContent(
        from inputItem: [String: Any]
    ) -> (content: String?, isPresent: Bool) {
        if let rawReasoning = inputItem["reasoning_content"] {
            guard let reasoning = stringValue(rawReasoning) else {
                return (nil, false)
            }
            return (reasoning, true)
        }
        guard let reasoning = stringValue(inputItem["reasoning"]), !reasoning.isEmpty else {
            return (nil, false)
        }
        return (reasoning, true)
    }

    private static func chatToolCallObject(_ toolCall: OpenCodeGoToolCall) -> [String: Any] {
        [
            "id": toolCall.id,
            "type": "function",
            "function": ["name": toolCall.name, "arguments": toolCall.arguments]
        ]
    }

    private static func toolCall(
        from object: [String: Any],
        toolContext: OpenCodeGoToolContext,
        kind: String?
    ) -> OpenCodeGoToolCall? {
        guard
            let id = stringValue(object["call_id"] ?? object["id"]),
            let responseName = stringValue(object["name"] ?? (object["function"] as? [String: Any])?["name"]),
            !id.isEmpty,
            !responseName.isEmpty
        else {
            return nil
        }
        let expectedKind: OpenCodeGoResponsesToolKind? = kind == "custom_tool_call" ? .custom : nil
        let chatName = toolContext.chatName(forResponseName: responseName, kind: expectedKind) ?? responseName
        let arguments: String
        if kind == "custom_tool_call" {
            let input = stringValue(object["input"]) ?? ""
            arguments = (try? JSONSerialization.data(withJSONObject: ["input": input], options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"input\":\"\"}"
        } else {
            arguments = stringValue(
                object["arguments"] ?? (object["function"] as? [String: Any])?["arguments"]
            ) ?? ""
        }
        return OpenCodeGoToolCall(id: id, name: chatName, arguments: arguments)
    }

    private static func toolOutputString(from rawOutput: Any?) -> String {
        if let output = rawOutput as? String { return output }
        if let parts = rawOutput as? [[String: Any]] {
            let text = parts.compactMap { stringValue($0["text"]) }.joined()
            if !text.isEmpty { return text }
        }
        return stringValue(rawOutput) ?? ""
    }

    private static func isToolCallOutput(_ inputItem: [String: Any]) -> Bool {
        let type = inputItem["type"] as? String
        return type == "function_call_output" || type == "custom_tool_call_output"
    }

    private static func toolCallOutputID(in inputItem: [String: Any]) -> String? {
        guard isToolCallOutput(inputItem) else { return nil }
        return trimmedString(inputItem["call_id"] ?? inputItem["tool_call_id"])
    }

    /// Collects call IDs already present in the Responses `input`, including
    /// standalone function/custom calls and assistant messages that embed
    /// Chat-shaped `tool_calls` or content-part tool calls.
    private static func toolCallIDs(in inputItem: [String: Any]) -> [String] {
        let type = inputItem["type"] as? String
        if type == "function_call" || type == "custom_tool_call" {
            if let id = trimmedString(inputItem["call_id"] ?? inputItem["id"]) {
                return [id]
            }
            return []
        }

        guard (inputItem["role"] as? String) == "assistant" else {
            return []
        }

        var ids: [String] = []
        if let toolCalls = inputItem["tool_calls"] as? [[String: Any]] {
            for toolCall in toolCalls {
                if let id = trimmedString(toolCall["id"] ?? toolCall["call_id"]) {
                    ids.append(id)
                }
            }
        }
        if let parts = inputItem["content"] as? [[String: Any]] {
            for part in parts {
                let partType = part["type"] as? String
                guard partType == "function_call" || partType == "custom_tool_call" else {
                    continue
                }
                if let id = trimmedString(part["call_id"] ?? part["id"]) {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    private static func isCompactionTrigger(_ inputItem: [String: Any]) -> Bool {
        inputItem["type"] as? String == "compaction_trigger"
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        return (value as? NSNumber)?.stringValue
    }
}
