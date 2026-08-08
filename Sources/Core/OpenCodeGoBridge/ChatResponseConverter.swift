import Foundation

/// Parses a buffered OpenAI-compatible Chat Completions JSON or SSE response
/// and produces a complete, legal Responses event sequence. The encoder never
/// forwards the Chat API's `[DONE]` marker.
public enum OpenCodeGoChatResponseConverter {
    public static func convert(
        chatResponse: Data,
        contentType: String? = nil,
        fallbackModel: String,
        toolContext: OpenCodeGoToolContext = OpenCodeGoToolContext(),
        outputMode: OpenCodeGoResponsesOutputMode = .standard,
        preferredResponseID: String? = nil
    ) throws -> OpenCodeGoResponsesConversion {
        let payloads: [[String: Any]]
        let text = String(data: chatResponse, encoding: .utf8) ?? ""
        if contentType?.lowercased().contains("text/event-stream") == true
            || text.contains("\ndata:")
            || text.hasPrefix("data:")
        {
            payloads = try OpenCodeGoChatSSEParser.payloads(from: chatResponse)
        } else {
            guard let payload = try JSONSerialization.jsonObject(with: chatResponse) as? [String: Any] else {
                throw OpenCodeGoBridgeError.invalidUpstreamResponse
            }
            payloads = [payload]
        }

        var accumulation = OpenCodeGoChatCompletionAccumulation()
        for payload in payloads {
            try accumulation.ingest(payload)
        }
        guard accumulation.sawCompletion else {
            throw OpenCodeGoBridgeError.invalidUpstreamResponse
        }

        let responseID: String
        if let preferred = preferredResponseID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty
        {
            responseID = preferred
        } else {
            responseID = makeResponseID(from: accumulation.sourceID)
        }
        let toolCalls = accumulation.completedToolCalls
        let separated = OpenCodeGoReasoningTagExtractor.extract(from: accumulation.text)
        let reasoning = accumulation.reasoning + separated.reasoning
        let model = accumulation.model ?? fallbackModel
        let reasoningContentPresent = accumulation.reasoningContentPresent ||
            !reasoning.isEmpty ||
            (!toolCalls.isEmpty && OpenCodeGoThinkingProfile.infer(model: model)?.requiresToolCallReasoningPlaceholder == true)
        let createdAt = accumulation.createdAt ?? Int(Date().timeIntervalSince1970)
        let usage = normalizedUsage(accumulation.usage)
        let sse: Data
        switch outputMode {
        case .standard:
            sse = try OpenCodeGoResponsesEventEncoder.stream(
                responseID: responseID,
                model: model,
                createdAt: createdAt,
                reasoning: reasoning,
                text: separated.visibleText,
                toolCalls: toolCalls,
                toolContext: toolContext,
                usage: usage,
                finishReason: accumulation.finishReason
            )
        case .compaction:
            guard toolCalls.isEmpty else {
                throw OpenCodeGoBridgeError.invalidUpstreamResponse
            }
            let summary = separated.visibleText.isEmpty ? reasoning : separated.visibleText
            guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenCodeGoBridgeError.invalidUpstreamResponse
            }
            sse = try OpenCodeGoResponsesEventEncoder.compactionStream(
                responseID: responseID,
                model: model,
                createdAt: createdAt,
                summary: summary,
                usage: usage,
                finishReason: accumulation.finishReason
            )
        }
        return OpenCodeGoResponsesConversion(
            responseID: responseID,
            sse: sse,
            toolCalls: toolCalls,
            reasoningContent: reasoningContentPresent ? reasoning : nil,
            reasoningContentPresent: reasoningContentPresent
        )
    }

    public static func failureSSE(
        for error: Error,
        fallbackModel: String
    ) -> Data {
        let normalized = OpenCodeGoBridgeErrorNormalizer.normalize(error)
        return OpenCodeGoResponsesEventEncoder.failure(
            responseID: "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            model: fallbackModel,
            normalizedError: normalized
        )
    }

    private static func makeResponseID(from sourceID: String?) -> String {
        let source = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = source?
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            .map(String.init)
            .joined() ?? ""
        if safe.hasPrefix("resp_") {
            return String(safe.prefix(128))
        }
        if !safe.isEmpty {
            return "resp_\(String(safe.prefix(120)))"
        }
        return "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private static func normalizedUsage(_ usage: [String: Any]?) -> [String: Any]? {
        guard let usage else {
            return nil
        }
        let inputTokens = integerValue(usage["input_tokens"] ?? usage["prompt_tokens"])
        let outputTokens = integerValue(usage["output_tokens"] ?? usage["completion_tokens"])
        let totalTokens = integerValue(usage["total_tokens"])
        guard inputTokens != nil || outputTokens != nil || totalTokens != nil else {
            return nil
        }

        var normalized: [String: Any] = [:]
        if let inputTokens {
            normalized["input_tokens"] = inputTokens
        }
        if let outputTokens {
            normalized["output_tokens"] = outputTokens
        }
        normalized["total_tokens"] = totalTokens ?? ((inputTokens ?? 0) + (outputTokens ?? 0))
        return normalized
    }
}

/// Parses complete Server-Sent Event bytes after the bridge has buffered the
/// upstream Chat response. Fragmented network reads are immaterial because
/// parsing happens only after the full body has been collected.
public enum OpenCodeGoChatSSEParser {
    public static func payloads(from data: Data) throws -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeGoBridgeError.invalidUpstreamResponse
        }

        var payloads: [[String: Any]] = []
        var dataLines: [String] = []

        func flush() throws {
            defer { dataLines.removeAll(keepingCapacity: true) }
            guard !dataLines.isEmpty else {
                return
            }
            let rawPayload = dataLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPayload.isEmpty, rawPayload != "[DONE]" else {
                return
            }
            guard
                let rawData = rawPayload.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: rawData) as? [String: Any]
            else {
                throw OpenCodeGoBridgeError.invalidUpstreamResponse
            }
            payloads.append(object)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.last == "\r" ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty {
                try flush()
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst("data:".count)
                dataLines.append(value.first == " " ? String(value.dropFirst()) : String(value))
            }
        }
        try flush()
        return payloads
    }
}

private struct OpenCodeGoChatCompletionAccumulation {
    private struct PartialToolCall {
        var id: String?
        var name: String?
        var arguments = ""
    }

    var sourceID: String?
    var model: String?
    var createdAt: Int?
    var text = ""
    var reasoning = ""
    var reasoningContentPresent = false
    var usage: [String: Any]?
    var finishReason: String?
    var sawCompletion = false
    private var partialToolCalls: [Int: PartialToolCall] = [:]
    private var toolCallOrder: [Int] = []

    var completedToolCalls: [OpenCodeGoToolCall] {
        toolCallOrder.compactMap { index in
            guard let partial = partialToolCalls[index],
                  let id = partial.id,
                  let name = partial.name,
                  !id.isEmpty,
                  !name.isEmpty
            else {
                return nil
            }
            return OpenCodeGoToolCall(id: id, name: name, arguments: partial.arguments)
        }
    }

    mutating func ingest(_ payload: [String: Any]) throws {
        if payload["error"] != nil {
            throw OpenCodeGoBridgeError.upstreamRejected
        }

        if sourceID == nil {
            sourceID = payload["id"] as? String
        }
        if model == nil {
            model = payload["model"] as? String
        }
        if createdAt == nil {
            createdAt = integerValue(payload["created"])
        }
        if let usage = payload["usage"] as? [String: Any] {
            self.usage = usage
        }

        guard let choices = payload["choices"] as? [[String: Any]] else {
            return
        }
        sawCompletion = true
        for (choiceOffset, choice) in choices.enumerated() {
            let payloadMessage = (choice["delta"] as? [String: Any])
                ?? (choice["message"] as? [String: Any])
                ?? [:]

            text += contentString(payloadMessage["content"])
            if let rawReasoning = payloadMessage["reasoning_content"] {
                reasoningContentPresent = true
                reasoning += contentString(rawReasoning)
            } else if let rawReasoning = payloadMessage["reasoning"] {
                reasoningContentPresent = true
                reasoning += contentString(rawReasoning)
            } else if let rawReasoning = payloadMessage["reasoning_text"] {
                reasoningContentPresent = true
                reasoning += contentString(rawReasoning)
            }

            if let toolCalls = payloadMessage["tool_calls"] as? [[String: Any]] {
                for (toolOffset, toolCall) in toolCalls.enumerated() {
                    let index = integerValue(toolCall["index"]) ?? (choiceOffset * 1000 + toolOffset)
                    if partialToolCalls[index] == nil {
                        partialToolCalls[index] = PartialToolCall()
                        toolCallOrder.append(index)
                    }
                    if let id = toolCall["id"] as? String, !id.isEmpty {
                        partialToolCalls[index]?.id = id
                    }
                    if let function = toolCall["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty {
                            partialToolCalls[index]?.name = name
                        }
                        partialToolCalls[index]?.arguments += contentString(function["arguments"])
                    }
                    if let name = toolCall["name"] as? String, !name.isEmpty {
                        partialToolCalls[index]?.name = name
                    }
                    partialToolCalls[index]?.arguments += contentString(toolCall["arguments"])
                }
            }

            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                finishReason = reason
            }
        }
    }
}

private enum OpenCodeGoReasoningTagExtractor {
    private static let opening = "<think>"
    private static let closing = "</think>"

    static func extract(from text: String) -> (visibleText: String, reasoning: String) {
        var visible = ""
        var reasoning = ""
        var cursor = text.startIndex
        var isThinking = false

        while cursor < text.endIndex {
            let openingRange = text.range(of: opening, range: cursor..<text.endIndex)
            let closingRange = text.range(of: closing, range: cursor..<text.endIndex)
            let marker: (range: Range<String.Index>, isOpening: Bool)?

            switch (openingRange, closingRange) {
            case let (.some(openingRange), .some(closingRange)):
                marker = openingRange.lowerBound < closingRange.lowerBound
                    ? (openingRange, true)
                    : (closingRange, false)
            case let (.some(openingRange), .none):
                marker = (openingRange, true)
            case let (.none, .some(closingRange)):
                marker = (closingRange, false)
            case (.none, .none):
                marker = nil
            }

            guard let marker else {
                if isThinking {
                    // An unclosed opening tag is treated as reasoning so
                    // untrusted chain-of-thought markup cannot leak as text.
                    reasoning += String(text[cursor...])
                } else {
                    visible += String(text[cursor...])
                }
                break
            }

            if isThinking {
                reasoning += String(text[cursor..<marker.range.lowerBound])
            } else {
                visible += String(text[cursor..<marker.range.lowerBound])
            }
            cursor = marker.range.upperBound

            if marker.isOpening {
                isThinking = true
            } else if isThinking {
                isThinking = false
            }
            // A stray closing marker is consumed rather than sent as text.
        }
        return (visible, reasoning)
    }
}

enum OpenCodeGoResponsesEventEncoder {
    static func compactionStream(
        responseID: String,
        model: String,
        createdAt: Int,
        summary: String,
        usage: [String: Any]?,
        finishReason: String?
    ) throws -> Data {
        var stream = ""
        let inProgressResponse = responseObject(
            id: responseID,
            model: model,
            createdAt: createdAt,
            status: "in_progress",
            output: [],
            usage: nil,
            incompleteDetails: nil,
            error: nil
        )
        try append(
            type: "response.created",
            payload: ["type": "response.created", "response": inProgressResponse],
            to: &stream
        )
        try append(
            type: "response.in_progress",
            payload: ["type": "response.in_progress", "response": inProgressResponse],
            to: &stream
        )

        let itemID = "cmp_\(responseID)"
        let inProgressItem: [String: Any] = [
            "id": itemID,
            "type": "compaction",
            "encrypted_content": ""
        ]
        try append(
            type: "response.output_item.added",
            payload: [
                "type": "response.output_item.added",
                "output_index": 0,
                "item": inProgressItem
            ],
            to: &stream
        )

        let completeItem: [String: Any] = [
            "id": itemID,
            "type": "compaction",
            "encrypted_content": OpenCodeGoCompactionEnvelope.wrap(summary)
        ]
        try appendOutputItemDone(
            completeItem,
            itemID: itemID,
            outputIndex: 0,
            to: &stream
        )

        let isLength = finishReason?.lowercased() == "length"
        let completedResponse = responseObject(
            id: responseID,
            model: model,
            createdAt: createdAt,
            status: isLength ? "incomplete" : "completed",
            output: [completeItem],
            usage: usage,
            incompleteDetails: isLength ? ["reason": "max_output_tokens"] : nil,
            error: nil
        )
        try append(
            type: "response.completed",
            payload: ["type": "response.completed", "response": completedResponse],
            to: &stream
        )
        return Data(stream.utf8)
    }

    static func stream(
        responseID: String,
        model: String,
        createdAt: Int,
        reasoning: String,
        text: String,
        toolCalls: [OpenCodeGoToolCall],
        toolContext: OpenCodeGoToolContext,
        usage: [String: Any]?,
        finishReason: String?
    ) throws -> Data {
        var output: [[String: Any]] = []
        var stream = ""
        let inProgressResponse = responseObject(
            id: responseID,
            model: model,
            createdAt: createdAt,
            status: "in_progress",
            output: [],
            usage: nil,
            incompleteDetails: nil,
            error: nil
        )
        try append(
            type: "response.created",
            payload: ["type": "response.created", "response": inProgressResponse],
            to: &stream
        )
        try append(
            type: "response.in_progress",
            payload: ["type": "response.in_progress", "response": inProgressResponse],
            to: &stream
        )

        var outputIndex = 0
        if !reasoning.isEmpty {
            let itemID = "rs_\(responseID)"
            let inProgressItem: [String: Any] = [
                "id": itemID,
                "type": "reasoning",
                "status": "in_progress",
                "summary": []
            ]
            try append(
                type: "response.output_item.added",
                payload: [
                    "type": "response.output_item.added",
                    "output_index": outputIndex,
                    "item": inProgressItem
                ],
                to: &stream
            )
            try append(
                type: "response.reasoning_summary_part.added",
                payload: [
                    "type": "response.reasoning_summary_part.added",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "summary_index": 0,
                    "part": ["type": "summary_text", "text": ""]
                ],
                to: &stream
            )
            try append(
                type: "response.reasoning_summary_text.delta",
                payload: [
                    "type": "response.reasoning_summary_text.delta",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "summary_index": 0,
                    "delta": reasoning
                ],
                to: &stream
            )
            try append(
                type: "response.reasoning_summary_text.done",
                payload: [
                    "type": "response.reasoning_summary_text.done",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "summary_index": 0,
                    "text": reasoning
                ],
                to: &stream
            )
            try append(
                type: "response.reasoning_summary_part.done",
                payload: [
                    "type": "response.reasoning_summary_part.done",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "summary_index": 0,
                    "part": ["type": "summary_text", "text": reasoning]
                ],
                to: &stream
            )
            let completeItem: [String: Any] = [
                "id": itemID,
                "type": "reasoning",
                "status": "completed",
                "summary": [["type": "summary_text", "text": reasoning]]
            ]
            try appendOutputItemDone(
                completeItem,
                itemID: itemID,
                outputIndex: outputIndex,
                to: &stream
            )
            output.append(completeItem)
            outputIndex += 1
        }

        if !text.isEmpty {
            let itemID = "msg_\(responseID)"
            let inProgressItem: [String: Any] = [
                "id": itemID,
                "type": "message",
                "status": "in_progress",
                "role": "assistant",
                "content": []
            ]
            try append(
                type: "response.output_item.added",
                payload: [
                    "type": "response.output_item.added",
                    "output_index": outputIndex,
                    "item": inProgressItem
                ],
                to: &stream
            )
            try append(
                type: "response.content_part.added",
                payload: [
                    "type": "response.content_part.added",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "content_index": 0,
                    "part": ["type": "output_text", "text": ""]
                ],
                to: &stream
            )
            try append(
                type: "response.output_text.delta",
                payload: [
                    "type": "response.output_text.delta",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "content_index": 0,
                    "delta": text
                ],
                to: &stream
            )
            try append(
                type: "response.output_text.done",
                payload: [
                    "type": "response.output_text.done",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "content_index": 0,
                    "text": text
                ],
                to: &stream
            )
            try append(
                type: "response.content_part.done",
                payload: [
                    "type": "response.content_part.done",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "content_index": 0,
                    "part": ["type": "output_text", "text": text]
                ],
                to: &stream
            )
            let completeItem: [String: Any] = [
                "id": itemID,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [["type": "output_text", "text": text]]
            ]
            try appendOutputItemDone(
                completeItem,
                itemID: itemID,
                outputIndex: outputIndex,
                to: &stream
            )
            output.append(completeItem)
            outputIndex += 1
        }

        for (callIndex, toolCall) in toolCalls.enumerated() {
            let mapping = toolContext.mapping(forChatName: toolCall.name)
                ?? OpenCodeGoToolMapping(
                    chatName: toolCall.name,
                    responseName: toolCall.name,
                    kind: .function
                )
            if mapping.kind == .function {
                try appendFunctionCall(
                    toolCall,
                    responseName: mapping.responseName,
                    itemID: "fc_\(responseID)_\(callIndex)",
                    outputIndex: outputIndex,
                    output: &output,
                    stream: &stream
                )
            } else {
                try appendInputToolCall(
                    toolCall,
                    mapping: mapping,
                    itemID: "\(mapping.kind == .custom ? "cc" : "ts")_\(responseID)_\(callIndex)",
                    outputIndex: outputIndex,
                    output: &output,
                    stream: &stream
                )
            }
            outputIndex += 1
        }

        let isLength = finishReason?.lowercased() == "length"
        let completedResponse = responseObject(
            id: responseID,
            model: model,
            createdAt: createdAt,
            status: isLength ? "incomplete" : "completed",
            output: output,
            usage: usage,
            incompleteDetails: isLength ? ["reason": "max_output_tokens"] : nil,
            error: nil
        )
        // A Responses stream must terminate with `response.completed` even
        // when the response itself is incomplete due to the token limit.
        try append(
            type: "response.completed",
            payload: [
                "type": "response.completed",
                "response": completedResponse
            ],
            to: &stream
        )
        return Data(stream.utf8)
    }

    static func failure(
        responseID: String,
        model: String,
        normalizedError: OpenCodeGoNormalizedError
    ) -> Data {
        let createdAt = Int(Date().timeIntervalSince1970)
        let error: [String: Any] = [
            "code": normalizedError.code,
            "message": normalizedError.message,
            "type": "server_error"
        ]
        let inProgressResponse = responseObject(
            id: responseID,
            model: model,
            createdAt: createdAt,
            status: "in_progress",
            output: [],
            usage: nil,
            incompleteDetails: nil,
            error: nil
        )
        let failedResponse = responseObject(
            id: responseID,
            model: model,
            createdAt: createdAt,
            status: "failed",
            output: [],
            usage: nil,
            incompleteDetails: nil,
            error: error
        )
        var stream = ""
        try? append(
            type: "response.created",
            payload: ["type": "response.created", "response": inProgressResponse],
            to: &stream
        )
        try? append(
            type: "response.in_progress",
            payload: ["type": "response.in_progress", "response": inProgressResponse],
            to: &stream
        )
        try? append(
            type: "response.failed",
            payload: [
                "type": "response.failed",
                "response": failedResponse,
                "error": error
            ],
            to: &stream
        )
        return Data(stream.utf8)
    }

    private static func appendFunctionCall(
        _ toolCall: OpenCodeGoToolCall,
        responseName: String,
        itemID: String,
        outputIndex: Int,
        output: inout [[String: Any]],
        stream: inout String
    ) throws {
        let inProgressItem: [String: Any] = [
            "id": itemID,
            "type": "function_call",
            "status": "in_progress",
            "call_id": toolCall.id,
            "name": responseName,
            "arguments": ""
        ]
        try append(
            type: "response.output_item.added",
            payload: [
                "type": "response.output_item.added",
                "output_index": outputIndex,
                "item": inProgressItem
            ],
            to: &stream
        )
        if !toolCall.arguments.isEmpty {
            try append(
                type: "response.function_call_arguments.delta",
                payload: [
                    "type": "response.function_call_arguments.delta",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "delta": toolCall.arguments
                ],
                to: &stream
            )
        }
        try append(
            type: "response.function_call_arguments.done",
            payload: [
                "type": "response.function_call_arguments.done",
                "item_id": itemID,
                "output_index": outputIndex,
                "arguments": toolCall.arguments
            ],
            to: &stream
        )
        let completeItem: [String: Any] = [
            "id": itemID,
            "type": "function_call",
            "status": "completed",
            "call_id": toolCall.id,
            "name": responseName,
            "arguments": toolCall.arguments
        ]
        try appendOutputItemDone(
            completeItem,
            itemID: itemID,
            outputIndex: outputIndex,
            to: &stream
        )
        output.append(completeItem)
    }

    private static func appendInputToolCall(
        _ toolCall: OpenCodeGoToolCall,
        mapping: OpenCodeGoToolMapping,
        itemID: String,
        outputIndex: Int,
        output: inout [[String: Any]],
        stream: inout String
    ) throws {
        let input = customInput(from: toolCall.arguments)
        let itemType = mapping.kind == .custom ? "custom_tool_call" : "tool_search_call"
        let eventPrefix = mapping.kind == .custom ? "custom_tool_call" : "tool_search_call"
        let inProgressItem: [String: Any] = [
            "id": itemID,
            "type": itemType,
            "status": "in_progress",
            "call_id": toolCall.id,
            "name": mapping.responseName,
            "input": ""
        ]
        try append(
            type: "response.output_item.added",
            payload: [
                "type": "response.output_item.added",
                "output_index": outputIndex,
                "item": inProgressItem
            ],
            to: &stream
        )
        if !input.isEmpty {
            try append(
                type: "response.\(eventPrefix)_input.delta",
                payload: [
                    "type": "response.\(eventPrefix)_input.delta",
                    "item_id": itemID,
                    "output_index": outputIndex,
                    "delta": input
                ],
                to: &stream
            )
        }
        try append(
            type: "response.\(eventPrefix)_input.done",
            payload: [
                "type": "response.\(eventPrefix)_input.done",
                "item_id": itemID,
                "output_index": outputIndex,
                "input": input
            ],
            to: &stream
        )
        let completeItem: [String: Any] = [
            "id": itemID,
            "type": itemType,
            "status": "completed",
            "call_id": toolCall.id,
            "name": mapping.responseName,
            "input": input
        ]
        try appendOutputItemDone(
            completeItem,
            itemID: itemID,
            outputIndex: outputIndex,
            to: &stream
        )
        output.append(completeItem)
    }

    private static func customInput(from arguments: String) -> String {
        guard
            let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let input = object["input"] as? String
        else {
            return arguments
        }
        return input
    }

    private static func appendOutputItemDone(
        _ item: [String: Any],
        itemID: String,
        outputIndex: Int,
        to stream: inout String
    ) throws {
        try append(
            type: "response.output_item.done",
            payload: [
                "type": "response.output_item.done",
                "item_id": itemID,
                "output_index": outputIndex,
                "item": item
            ],
            to: &stream
        )
    }

    private static func responseObject(
        id: String,
        model: String,
        createdAt: Int,
        status: String,
        output: [[String: Any]],
        usage: [String: Any]?,
        incompleteDetails: [String: Any]?,
        error: [String: Any]?
    ) -> [String: Any] {
        var response: [String: Any] = [
            "id": id,
            "object": "response",
            "created_at": createdAt,
            "status": status,
            "model": model,
            "output": output,
            "parallel_tool_calls": true,
            "tool_choice": "auto"
        ]
        if let usage {
            response["usage"] = usage
        }
        if let incompleteDetails {
            response["incomplete_details"] = incompleteDetails
        }
        if let error {
            response["error"] = error
        }
        return response
    }

    private static func append(
        type: String,
        payload: [String: Any],
        to stream: inout String
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenCodeGoBridgeError.invalidUpstreamResponse
        }
        stream += "event: \(type)\n"
        stream += "data: \(json)\n\n"
    }
}

private func contentString(_ value: Any?) -> String {
    guard let value else {
        return ""
    }
    if let string = value as? String {
        return string
    }
    guard let parts = value as? [[String: Any]] else {
        return ""
    }
    return parts.compactMap { part in
        (part["text"] as? String)
            ?? (part["content"] as? String)
            ?? (part["value"] as? String)
    }
    .joined()
}

private func integerValue(_ value: Any?) -> Int? {
    if let integer = value as? Int {
        return integer
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    return nil
}
