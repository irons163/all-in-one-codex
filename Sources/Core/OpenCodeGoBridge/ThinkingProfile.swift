import Foundation

/// Chat Completions thinking / reasoning controls inferred the same way
/// cc-switch's `infer_codex_chat_reasoning_config` does for OpenCode Go hosts.
/// Aggregation-platform overrides are omitted here: this bridge always talks to
/// `opencode.ai/zen/go`, so model-id inference is enough for v1.
struct OpenCodeGoThinkingProfile: Equatable, Sendable {
    enum ThinkingParam: String, Equatable, Sendable {
        case thinking
        case enableThinking = "enable_thinking"
        case none
    }

    enum OutputFormat: String, Equatable, Sendable {
        case reasoningContent = "reasoning_content"
    }

    let supportsThinking: Bool
    let thinkingParam: ThinkingParam
    let outputFormat: OutputFormat
    /// DeepSeek-only OpenCode Go constraints discovered by live probes.
    let rejectsForcedToolChoiceWhileThinking: Bool
    let rejectsJSONObjectResponseFormat: Bool

    /// Models that require non-empty `reasoning_content` on assistant tool-call
    /// turns (cc-switch `backfill_tool_call_reasoning_placeholders`).
    var requiresToolCallReasoningPlaceholder: Bool {
        supportsThinking && outputFormat == .reasoningContent
    }

    static func infer(model: String) -> OpenCodeGoThinkingProfile? {
        let haystack = model.lowercased()

        if haystack.contains("deepseek") {
            return OpenCodeGoThinkingProfile(
                supportsThinking: true,
                thinkingParam: .thinking,
                outputFormat: .reasoningContent,
                rejectsForcedToolChoiceWhileThinking: true,
                rejectsJSONObjectResponseFormat: true
            )
        }
        if haystack.contains("kimi") || haystack.contains("moonshot") {
            return OpenCodeGoThinkingProfile(
                supportsThinking: true,
                thinkingParam: .thinking,
                outputFormat: .reasoningContent,
                rejectsForcedToolChoiceWhileThinking: false,
                rejectsJSONObjectResponseFormat: false
            )
        }
        if haystack.contains("glm") || haystack.contains("zhipu") {
            return OpenCodeGoThinkingProfile(
                supportsThinking: true,
                thinkingParam: .thinking,
                outputFormat: .reasoningContent,
                rejectsForcedToolChoiceWhileThinking: false,
                rejectsJSONObjectResponseFormat: false
            )
        }
        if haystack.contains("mimo") {
            return OpenCodeGoThinkingProfile(
                supportsThinking: true,
                thinkingParam: .thinking,
                outputFormat: .reasoningContent,
                rejectsForcedToolChoiceWhileThinking: false,
                rejectsJSONObjectResponseFormat: false
            )
        }
        return nil
    }
}
