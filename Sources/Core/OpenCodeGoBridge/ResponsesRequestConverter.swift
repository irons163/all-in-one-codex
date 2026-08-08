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
        let isDeepSeekV4 = isDeepSeekV4Model(model)
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

        if let instructions = root["instructions"] as? String, !instructions.isEmpty {
            systemMessages.append(["role": "system", "content": instructions])
        }

        let previousResponseID = root["previous_response_id"] as? String
        let cachedHistory = previousResponseID.flatMap { toolCallCache?.history(for: $0) }
        if let cachedHistory, !cachedHistory.toolCalls.isEmpty {
            conversationMessages.append(
                assistantToolCallMessage(
                    cachedHistory.toolCalls,
                    reasoningContent: cachedHistory.reasoningContent,
                    reasoningContentPresent: cachedHistory.reasoningContentPresent,
                    requiresDeepSeekAssistantFields: isDeepSeekV4
                )
            )
        }

        if let input = root["input"] as? String {
            conversationMessages.append(["role": "user", "content": input])
        } else if let inputItems {
            for inputItem in inputItems {
                try appendChatMessages(
                    from: inputItem,
                    systemMessages: &systemMessages,
                    conversationMessages: &conversationMessages,
                    toolContext: toolConversion.context,
                    isDeepSeekV4: isDeepSeekV4
                )
            }
            if previousResponseID != nil,
               cachedHistory?.toolCalls.isEmpty ?? true,
               inputItems.contains(where: isToolCallOutput)
            {
                throw OpenCodeGoBridgeError.invalidRequest
            }
        } else if root["input"] != nil {
            throw OpenCodeGoBridgeError.invalidRequest
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
        for key in ["temperature", "top_p", "seed", "response_format"] {
            if let value = root[key] {
                chatRequest[key] = value
            }
        }
        if isDeepSeekV4, let thinking = deepSeekThinking(from: root) {
            chatRequest["thinking"] = thinking
        }

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

    private static func isDeepSeekV4Model(_ model: String) -> Bool {
        model.lowercased().contains("deepseek-v4")
    }

    private static func deepSeekThinking(from root: [String: Any]) -> [String: String]? {
        guard let effort = deepSeekReasoningEffort(from: root) else {
            return nil
        }
        let type = ["none", "off", "disabled"].contains(effort) ? "disabled" : "enabled"
        return ["type": type]
    }

    private static func deepSeekReasoningEffort(from root: [String: Any]) -> String? {
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
        isDeepSeekV4: Bool
    ) throws {
        let type = inputItem["type"] as? String
        if type == "compaction_trigger" {
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
            conversationMessages.append([
                "role": "system",
                "content": "Prior compacted conversation context:\n\(summary)"
            ])
            return
        }

        if isToolCallOutput(inputItem) {
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
            let reasoning = inputReasoningContent(from: inputItem)
            conversationMessages.append(
                assistantToolCallMessage(
                    [toolCall],
                    reasoningContent: reasoning.content,
                    reasoningContentPresent: reasoning.isPresent,
                    requiresDeepSeekAssistantFields: isDeepSeekV4
                )
            )
            return
        }

        let sourceRole = (inputItem["role"] as? String) ?? "user"
        guard ["system", "developer", "user", "assistant", "tool"].contains(sourceRole) else {
            throw OpenCodeGoBridgeError.invalidRequest
        }
        let role = sourceRole == "developer" || sourceRole == "system" ? "system" : sourceRole
        let convertedContent = chatContent(from: inputItem["content"], toolContext: toolContext)
        var message: [String: Any] = ["role": role]
        if let content = convertedContent.content {
            message["content"] = content
        } else if role != "assistant" || isDeepSeekV4 {
            message["content"] = ""
        }
        if role == "assistant", !convertedContent.toolCalls.isEmpty {
            message["tool_calls"] = convertedContent.toolCalls.map(chatToolCallObject)
        }
        if role == "assistant" {
            let topLevelReasoning = inputReasoningContent(from: inputItem)
            let reasoning = topLevelReasoning.isPresent
                ? topLevelReasoning
                : (
                    content: convertedContent.reasoningContent,
                    isPresent: convertedContent.reasoningContentPresent
                )
            if reasoning.isPresent || isDeepSeekV4 {
                message["reasoning_content"] = reasoning.content ?? ""
            }
        }
        if role == "tool" {
            guard let callID = stringValue(inputItem["call_id"] ?? inputItem["tool_call_id"]) else {
                throw OpenCodeGoBridgeError.invalidRequest
            }
            message["tool_call_id"] = callID
        }

        if role == "system" {
            systemMessages.append(message)
        } else {
            conversationMessages.append(message)
        }
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
                if function["parameters"] == nil || function["parameters"] is NSNull {
                    function["parameters"] = ["type": "object", "properties": [String: Any]()]
                }

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

    private static func assistantToolCallMessage(
        _ toolCalls: [OpenCodeGoToolCall],
        reasoningContent: String?,
        reasoningContentPresent: Bool = false,
        requiresDeepSeekAssistantFields: Bool = false
    ) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant"]
        if requiresDeepSeekAssistantFields {
            message["content"] = ""
        }
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls.map(chatToolCallObject) }
        if reasoningContentPresent || reasoningContent != nil || requiresDeepSeekAssistantFields {
            message["reasoning_content"] = reasoningContent ?? ""
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
