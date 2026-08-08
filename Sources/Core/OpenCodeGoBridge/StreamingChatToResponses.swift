import Foundation

/// Incremental Chat Completions SSE framing parser. Bytes may arrive mid-line;
/// complete `data:` events are yielded as JSON objects. Chat `[DONE]` is dropped.
/// This is the framing half of closing the buffer-only gap versus cc-switch
/// `streaming_codex_chat.rs`.
struct OpenCodeGoIncrementalChatSSEParser {
    private var pending = Data()
    private var dataLines: [String] = []

    mutating func push(_ chunk: Data) throws -> [[String: Any]] {
        pending.append(chunk)
        var payloads: [[String: Any]] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var lineData = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            let line = String(data: lineData, encoding: .utf8) ?? ""
            if line.isEmpty {
                if let payload = try flushDataLines() {
                    payloads.append(payload)
                }
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst("data:".count)
                dataLines.append(value.first == " " ? String(value.dropFirst()) : String(value))
            }
        }
        return payloads
    }

    mutating func finish() throws -> [[String: Any]] {
        var payloads: [[String: Any]] = []
        if !pending.isEmpty {
            let trailing = String(data: pending, encoding: .utf8) ?? ""
            pending.removeAll(keepingCapacity: false)
            if trailing.hasPrefix("data:") {
                let value = trailing.dropFirst("data:".count)
                dataLines.append(value.first == " " ? String(value.dropFirst()) : String(value))
            } else if trailing.contains("data:") {
                // Ignore incomplete non-data trailing bytes.
            }
        }
        if let payload = try flushDataLines() {
            payloads.append(payload)
        }
        return payloads
    }

    private mutating func flushDataLines() throws -> [String: Any]? {
        defer { dataLines.removeAll(keepingCapacity: true) }
        guard !dataLines.isEmpty else {
            return nil
        }
        let rawPayload = dataLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPayload.isEmpty, rawPayload != "[DONE]" else {
            return nil
        }
        guard
            let rawData = rawPayload.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: rawData) as? [String: Any]
        else {
            throw OpenCodeGoBridgeError.invalidUpstreamResponse
        }
        return object
    }
}

/// Converts a sequence of Chat Completions SSE payloads into a Responses SSE
/// body while supporting an early `response.created` / `response.in_progress`
/// flush before upstream finishes. Token/tool deltas are emitted once at the
/// end via the shared encoder so terminal event shape stays identical to the
/// buffered path (no duplicate deltas).
enum OpenCodeGoStreamingChatBridge {
    static func earlyLifecycleSSE(
        responseID: String,
        model: String,
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) throws -> Data {
        let response: [String: Any] = [
            "id": responseID,
            "object": "response",
            "created_at": createdAt,
            "status": "in_progress",
            "model": model,
            "output": [],
            "parallel_tool_calls": true,
            "tool_choice": "auto"
        ]
        var stream = ""
        try append(type: "response.created", payload: ["type": "response.created", "response": response], to: &stream)
        try append(type: "response.in_progress", payload: ["type": "response.in_progress", "response": response], to: &stream)
        return Data(stream.utf8)
    }

    /// Drops leading created/in_progress blocks so a later full conversion can
    /// be appended after `earlyLifecycleSSE` without duplicating them.
    static func stripLeadingLifecycle(from sse: Data) -> Data {
        guard var text = String(data: sse, encoding: .utf8) else {
            return sse
        }
        for _ in 0..<2 {
            guard text.hasPrefix("event: response.created\n")
                || text.hasPrefix("event: response.in_progress\n"),
                let range = text.range(of: "\n\n")
            else {
                break
            }
            text.removeSubrange(text.startIndex..<range.upperBound)
        }
        return Data(text.utf8)
    }

    private static func append(
        type: String,
        payload: [String: Any],
        to stream: inout String
    ) throws {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            throw OpenCodeGoBridgeError.invalidUpstreamResponse
        }
        stream += "event: \(type)\n"
        stream += "data: \(json)\n\n"
    }
}
