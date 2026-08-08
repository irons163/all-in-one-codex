import Darwin
import Foundation
import XCTest

@testable import AllInOneCodex

final class CodexCoreTests: XCTestCase {
    func testProviderCatalogContainsRequiredPresets() throws {
        let openCodeGo = try XCTUnwrap(ProviderCatalog.preset(for: .openCodeGo))
        XCTAssertEqual(openCodeGo.baseURL, "https://opencode.ai/zen/go/v1")
        XCTAssertEqual(openCodeGo.defaultModel, "glm-5.2")
        XCTAssertEqual(openCodeGo.providerID, "all_in_one_opencode_go_bridge")

        let openRouter = try XCTUnwrap(ProviderCatalog.preset(for: .openRouter))
        XCTAssertEqual(openRouter.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(openRouter.defaultModel, "openai/gpt-5.3-codex")
        XCTAssertEqual(openRouter.providerID, "all_in_one_openrouter")
    }

    func testProjectsBothPresetsWithCommandBackedAuthentication() throws {
        let projector = CodexConfigProjector()

        for preset in ProviderCatalog.all {
            let profile = makeProfile(presetID: preset.id)
            let projection = try projector.project(original: "# User configuration\n", profile: profile)

            XCTAssertTrue(projection.contains("model = \"\(profile.model)\""))
            XCTAssertTrue(projection.contains("model_provider = \"\(preset.providerID)\""))
            XCTAssertTrue(projection.contains("base_url = \"\(preset.baseURL)\""))
            XCTAssertTrue(projection.contains("wire_api = \"responses\""))
            XCTAssertTrue(
                projection.contains(
                    "args = [\"find-generic-password\", \"-s\", \"\(KeychainCredentialStore.service)\", \"-a\", \"\(profile.id.uuidString)\", \"-w\"]"
                )
            )
            XCTAssertTrue(projection.contains("timeout_ms = 5000"))
            XCTAssertTrue(projection.contains("refresh_interval_ms = 0"))

            for managedPreset in ProviderCatalog.all {
                XCTAssertTrue(
                    projection.contains("[model_providers.\(managedPreset.providerID)]"),
                    "Both app-owned provider tables must be projected."
                )
            }
            XCTAssertFalse(projection.contains("env_key"))
            XCTAssertFalse(projection.contains("requires_openai_auth"))
            XCTAssertFalse(projection.contains("experimental_bearer_token"))
        }
    }

    func testProjectionPreservesUnknownSettingsCommentsAndMCP() throws {
        let original = """
        # Keep this user comment.
        approval_policy = "never"
        model = "legacy-model"
        model_provider = "legacy-provider"

        [mcp_servers.filesystem] # preserve this table comment
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]

        [unknown_feature]
        enabled = true
        """
        let projection = try CodexConfigProjector().project(
            original: original,
            profile: makeProfile(presetID: .openRouter)
        )

        XCTAssertTrue(projection.contains("# Keep this user comment."))
        XCTAssertTrue(projection.contains("approval_policy = \"never\""))
        XCTAssertTrue(projection.contains("[mcp_servers.filesystem]"))
        XCTAssertTrue(projection.contains("# preserve this table comment"))
        XCTAssertTrue(projection.contains("@modelcontextprotocol/server-filesystem"))
        XCTAssertTrue(projection.contains("[unknown_feature]"))
        XCTAssertFalse(projection.contains("model = \"legacy-model\""))
        XCTAssertFalse(projection.contains("model_provider = \"legacy-provider\""))

        let activeMarker = try XCTUnwrap(projection.range(of: CodexConfigProjector.activeBeginMarker))
        let firstTable = try XCTUnwrap(projection.range(of: "[mcp_servers.filesystem]"))
        XCTAssertLessThan(activeMarker.lowerBound, firstTable.lowerBound)
    }

    func testProjectionRetainsMultilineUnknownTopLevelValues() throws {
        let original = #"""
        notes = """
        model = "this belongs to the note"
        [mcp_servers.not_a_table]
        """
        model = "legacy-model"
        model_provider = "legacy-provider"

        [mcp_servers.real]
        command = "real-mcp"
        """#

        let projection = try CodexConfigProjector().project(
            original: original,
            profile: makeProfile(presetID: .openCodeGo)
        )

        XCTAssertTrue(projection.contains("model = \"this belongs to the note\""))
        XCTAssertTrue(projection.contains("[mcp_servers.not_a_table]"))
        XCTAssertTrue(projection.contains("[mcp_servers.real]"))
        XCTAssertFalse(projection.contains("model = \"legacy-model\""))
        XCTAssertFalse(projection.contains("model_provider = \"legacy-provider\""))
    }

    func testMalformedManagedMarkerIsConflict() {
        let original = """
        # BEGIN ALL-IN-ONE-CODEX ACTIVE
        model = "incomplete"
        """

        XCTAssertThrowsError(
            try CodexConfigProjector().project(
                original: original,
                profile: makeProfile(presetID: .openCodeGo)
            )
        ) { error in
            XCTAssertEqual(error as? CodexSwitchError, .malformedManagedMarkers)
        }
    }

    func testProjectionAndApplyNeverIncludeCredentialMaterial() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configURL = directoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        let profile = makeProfile(presetID: .openCodeGo)
        let credentials = FakeCredentialStore()
        let keyMaterial = UUID().uuidString + UUID().uuidString
        try credentials.save(Data(keyMaterial.utf8), for: profile.id)

        let adapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            bridgeManager: FakeBridgeManager()
        )
        let preview = try adapter.preview(profile: profile)
        XCTAssertFalse(preview.projected.contains(keyMaterial))

        _ = try adapter.apply(profile: profile)
        let appliedConfiguration = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(appliedConfiguration.contains(keyMaterial))
    }

    func testApplyBacksUpAtomicallyUndoesAndDetectsHashConflict() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configDirectory = directoryURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("config.toml")
        let original = """
        # Existing setting
        approval_policy = "on-request"

        [mcp_servers.example]
        command = "example-mcp"
        """
        try Data(original.utf8).write(to: configURL)

        let profile = makeProfile(presetID: .openRouter)
        let credentials = FakeCredentialStore()
        try credentials.save(Data(repeating: 0xA5, count: 32), for: profile.id)
        let adapter = CodexClientAdapter(configURL: configURL, credentialStore: credentials)

        let receipt = try adapter.apply(profile: profile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.backupURL.path))
        XCTAssertNotEqual(try String(contentsOf: configURL, encoding: .utf8), original)

        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o777, 0o600)

        try adapter.undo(receipt)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)

        let secondReceipt = try adapter.apply(profile: profile)
        try Data("# External edit\n".utf8).write(to: configURL)
        XCTAssertThrowsError(try adapter.undo(secondReceipt)) { error in
            XCTAssertEqual(error as? CodexSwitchError, .configurationChanged)
        }
    }

    func testProfileRepositoryRoundTripsMetadataWithoutCredentials() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let profile = makeProfile(presetID: .openRouter)
        let repository = ProfileRepository(
            storageURL: directoryURL
                .appendingPathComponent("AllInOneCodex", isDirectory: true)
                .appendingPathComponent("profiles.json")
        )

        try await repository.save([profile])
        let loadedProfiles = try await repository.load()
        XCTAssertEqual(loadedProfiles, [profile])
    }

    func testOpenCodeGoCapabilityCatalogContainsOfficialWireAPIs() {
        let responses = ProviderCatalog.openCodeGoModels
            .filter { $0.wireAPI == .responses }
            .map(\.modelID)
        let chat = Set(
            ProviderCatalog.openCodeGoModels
                .filter { $0.wireAPI == .chatCompletions }
                .map(\.modelID)
        )
        let messages = Set(
            ProviderCatalog.openCodeGoModels
                .filter { $0.wireAPI == .anthropicMessages }
                .map(\.modelID)
        )

        XCTAssertEqual(responses, ["gpt-5.6-luna"])
        XCTAssertEqual(
            chat,
            [
                "grok-4.5", "glm-5.2", "glm-5.1", "kimi-k3",
                "kimi-k2.7-code", "kimi-k2.6", "deepseek-v4-pro",
                "deepseek-v4-flash", "mimo-v2.5", "mimo-v2.5-pro", "hy3"
            ]
        )
        XCTAssertEqual(
            messages,
            [
                "minimax-m3", "minimax-m2.7", "qwen3.8-max",
                "qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus"
            ]
        )
    }

    func testRoutesDirectResponsesChatBridgeAndRejectsMessages() throws {
        let direct = try ProviderCatalog.route(
            for: makeProfile(presetID: .openCodeGo, model: "gpt-5.6-luna")
        )
        XCTAssertEqual(direct.providerID, "all_in_one_opencode_go")
        XCTAssertEqual(direct.baseURL, "https://opencode.ai/zen/go/v1")
        XCTAssertFalse(direct.requiresLoopbackBridge)

        let chat = try ProviderCatalog.route(
            for: makeProfile(presetID: .openCodeGo, model: "glm-5.2")
        )
        XCTAssertEqual(chat.providerID, "all_in_one_opencode_go_bridge")
        XCTAssertEqual(chat.baseURL, "http://127.0.0.1:14556/v1")
        XCTAssertEqual(chat.wireAPI, .responses)
        XCTAssertTrue(chat.requiresLoopbackBridge)

        let openRouter = try ProviderCatalog.route(
            for: makeProfile(presetID: .openRouter, model: "vendor/custom-model")
        )
        XCTAssertEqual(openRouter.providerID, "all_in_one_openrouter")
        XCTAssertEqual(openRouter.wireAPI, .responses)
        XCTAssertFalse(openRouter.requiresLoopbackBridge)

        XCTAssertThrowsError(
            try ProviderCatalog.route(
                for: makeProfile(presetID: .openCodeGo, model: "qwen3.8-max")
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderRoutingError,
                .unsupportedOpenCodeGoWireAPI(.anthropicMessages)
            )
        }
        XCTAssertThrowsError(
            try ProviderCatalog.route(
                for: makeProfile(presetID: .openCodeGo, model: "unlisted-model")
            )
        ) { error in
            XCTAssertEqual(error as? ProviderRoutingError, .unknownOpenCodeGoModel)
        }
    }

    func testChatProjectionUsesLoopbackWithoutFixtureCredential() throws {
        let fixtureSecret = "fixture-secret-must-not-appear"
        let profile = ProviderProfile(
            name: fixtureSecret,
            presetID: .openCodeGo,
            model: "glm-5.2",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let original = """
        # preserve this comment
        [mcp_servers.test]
        command = "test-mcp"
        """

        let projection = try CodexConfigProjector().project(
            original: original,
            profile: profile
        )

        XCTAssertTrue(
            projection.contains("model_provider = \"all_in_one_opencode_go_bridge\"")
        )
        XCTAssertTrue(
            projection.contains(
                "[model_providers.all_in_one_opencode_go_bridge]"
            )
        )
        XCTAssertTrue(
            projection.contains(
                "base_url = \"http://127.0.0.1:14556/v1\""
            )
        )
        XCTAssertTrue(projection.contains("# preserve this comment"))
        XCTAssertTrue(projection.contains("[mcp_servers.test]"))
        XCTAssertTrue(projection.contains("/usr/bin/security"))
        XCTAssertFalse(projection.contains(fixtureSecret))
    }

    func testConvertsInstructionsInputContentToolsAndTokenOptions() throws {
        let request = """
        {
          "model": "glm-5.2",
          "instructions": "Follow the system rule.",
          "input": [{
            "role": "user",
            "content": [
              {"type": "input_text", "text": "Describe this."},
              {"type": "input_image", "image_url": "https://example.invalid/image.png"},
              {"type": "input_file", "file_id": "file_123", "filename": "brief.pdf"},
              {"type": "input_audio", "input_audio": {"format": "wav", "data": "AA=="}}
            ]
          }],
          "tools": [{
            "type": "function",
            "name": "lookup_weather",
            "description": "Looks up weather.",
            "parameters": {"type": "object", "properties": {"city": {"type": "string"}}}
          }],
          "tool_choice": {"type": "function", "name": "lookup_weather"},
          "parallel_tool_calls": true,
          "max_output_tokens": 512,
          "stream": true,
          "stream_options": {"include_usage": false}
        }
        """

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Follow the system rule.")

        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, [
            "text", "image_url", "file", "input_audio"
        ])
        XCTAssertEqual(
            (content[1]["image_url"] as? [String: Any])?["url"] as? String,
            "https://example.invalid/image.png"
        )
        XCTAssertEqual(chat["max_tokens"] as? Int, 512)
        XCTAssertEqual(chat["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(
            (chat["stream_options"] as? [String: Any])?["include_usage"] as? Bool,
            true
        )
        let tools = try XCTUnwrap(chat["tools"] as? [[String: Any]])
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(
            ((tools[0]["function"] as? [String: Any])?["name"] as? String),
            "lookup_weather"
        )
        XCTAssertEqual(
            ((chat["tool_choice"] as? [String: Any])?["function"] as? [String: Any])?["name"] as? String,
            "lookup_weather"
        )
    }

    func testConvertsAssistantInputFunctionCalls() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "input": [[
                "role": "assistant",
                "content": [
                    ["type": "output_text", "text": "I will look that up."],
                    [
                        "type": "function_call",
                        "call_id": "call_lookup",
                        "name": "lookup_weather",
                        "arguments": "{\"city\":\"Taipei\"}"
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: data
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let message = try XCTUnwrap((chat["messages"] as? [[String: Any]])?.first)
        let toolCall = try XCTUnwrap((message["tool_calls"] as? [[String: Any]])?.first)

        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertEqual(
            ((message["content"] as? [[String: Any]])?.first?["text"] as? String),
            "I will look that up."
        )
        XCTAssertEqual(toolCall["id"] as? String, "call_lookup")
        XCTAssertEqual(
            ((toolCall["function"] as? [String: Any])?["arguments"] as? String),
            "{\"city\":\"Taipei\"}"
        )
    }

    func testConvertsTextSSEToResponsesTerminalSequence() throws {
        let upstream = """
        data: {"id":"chatcmpl_text","model":"glm-5.2","created":1700000000,"choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}

        data: {"id":"chatcmpl_text","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}

        data: [DONE]

        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.created"))
        XCTAssertTrue(events.contains("event: response.in_progress"))
        XCTAssertTrue(events.contains("event: response.output_text.delta"))
        XCTAssertTrue(events.contains("Hello world"))
        XCTAssertTrue(events.contains("event: response.output_item.done"))
        XCTAssertTrue(events.contains("event: response.completed"))
        XCTAssertTrue(events.contains("\"input_tokens\":4"))
        XCTAssertFalse(events.contains("[DONE]"))
    }

    func testConvertsReasoningSSEToResponsesReasoningEvents() throws {
        let upstream = """
        data: {"id":"chatcmpl_reasoning","model":"glm-5.2","choices":[{"index":0,"delta":{"reasoning_content":"I should check the units.","content":"The answer is 42."},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.reasoning_summary_text.delta"))
        XCTAssertTrue(events.contains("I should check the units."))
        XCTAssertTrue(events.contains("The answer is 42."))
        XCTAssertTrue(events.contains("event: response.completed"))
    }

    func testCoalescesFragmentedToolArgumentsFromSSE() throws {
        let upstream = #"""
        data: {"id":"chatcmpl_tool","model":"glm-5.2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_weather","type":"function","function":{"name":"lookup_weather","arguments":"{\"city\":\""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl_tool","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"Taipei\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """#
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2"
        )
        let toolCall = try XCTUnwrap(conversion.toolCalls.first)
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertEqual(toolCall.id, "call_weather")
        XCTAssertEqual(toolCall.name, "lookup_weather")
        XCTAssertEqual(toolCall.arguments, "{\"city\":\"Taipei\"}")
        XCTAssertTrue(events.contains("event: response.function_call_arguments.delta"))
        XCTAssertTrue(events.contains("event: response.function_call_arguments.done"))
    }

    func testMapsUsageAndLengthFinishReason() throws {
        let upstream = """
        {
          "id": "chatcmpl_length",
          "model": "glm-5.2",
          "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": "Partial answer"},
            "finish_reason": "length"
          }],
          "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}
        }
        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.completed"))
        XCTAssertFalse(events.contains("event: response.incomplete"))
        XCTAssertTrue(events.contains("\"status\":\"incomplete\""))
        XCTAssertTrue(events.contains("\"reason\":\"max_output_tokens\""))
        XCTAssertTrue(events.contains("\"input_tokens\":7"))
        XCTAssertTrue(events.contains("\"output_tokens\":3"))
        XCTAssertTrue(events.contains("\"total_tokens\":10"))
    }

    func testPreviousResponseToolOutputRebuildsAssistantToolCalls() throws {
        let cache = OpenCodeGoToolCallCache(capacity: 2)
        cache.store(
            responseID: "resp_prior",
            toolCalls: [
                OpenCodeGoToolCall(
                    id: "call_lookup",
                    name: "lookup_weather",
                    arguments: "{\"city\":\"Taipei\"}"
                )
            ],
            reasoningContent: "I should preserve this context."
        )
        let request: [String: Any] = [
            "model": "glm-5.2",
            "previous_response_id": "resp_prior",
            "input": [[
                "type": "function_call_output",
                "call_id": "call_lookup",
                "output": "Sunny"
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: data,
            toolCallCache: cache
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])

        XCTAssertEqual(messages[0]["role"] as? String, "assistant")
        XCTAssertEqual(
            (((messages[0]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String),
            "lookup_weather"
        )
        XCTAssertEqual(
            messages[0]["reasoning_content"] as? String,
            "I should preserve this context."
        )
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "call_lookup")
        XCTAssertEqual(messages[1]["content"] as? String, "Sunny")
    }

    func testKeepsToolHistoryBoundedWhileRetainingReasoning() {
        let cache = OpenCodeGoToolCallCache(capacity: 1)
        cache.store(
            responseID: "resp_first",
            toolCalls: [OpenCodeGoToolCall(id: "call_first", name: "first", arguments: "{}")],
            reasoningContent: "first reasoning"
        )
        cache.store(
            responseID: "resp_second",
            toolCalls: [OpenCodeGoToolCall(id: "call_second", name: "second", arguments: "{}")],
            reasoningContent: "second reasoning"
        )

        XCTAssertNil(cache.history(for: "resp_first"))
        XCTAssertEqual(
            cache.history(for: "resp_second")?.reasoningContent,
            "second reasoning"
        )
    }

    func testNormalizesErrorsWithoutLeakingUpstreamPayloads() {
        let encoding = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.unsupportedContentEncoding
        )
        XCTAssertEqual(encoding.statusCode, 415)
        XCTAssertEqual(encoding.code, "unsupported_content_encoding")

        let upstream = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 429
        )
        XCTAssertEqual(upstream.statusCode, 429)
        XCTAssertEqual(upstream.code, "upstream_rate_limited")

        let failure = OpenCodeGoChatResponseConverter.failureSSE(
            for: OpenCodeGoBridgeError.upstreamRejected,
            fallbackModel: "glm-5.2"
        )
        let events = String(data: failure, encoding: .utf8) ?? ""
        XCTAssertTrue(events.contains("event: response.failed"))
        XCTAssertFalse(events.contains("fixture-secret-must-not-leak"))
    }

    func testChatApplyEnsuresBridgeBeforeConfigurationAndDirectApplyDoesNot() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configURL = directoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")

        let credentials = FakeCredentialStore()
        let chatProfile = makeProfile(presetID: .openCodeGo, model: "glm-5.2")
        try credentials.save(Data("test-credential".utf8), for: chatProfile.id)
        let chatBridge = FakeBridgeManager()
        chatBridge.onEnsure = {
            XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        }
        let chatAdapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            bridgeManager: chatBridge
        )

        _ = try chatAdapter.apply(profile: chatProfile)
        XCTAssertEqual(chatBridge.events, ["ensure"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))

        let directProfile = makeProfile(presetID: .openCodeGo, model: "gpt-5.6-luna")
        try credentials.save(Data("test-credential".utf8), for: directProfile.id)
        let directBridge = FakeBridgeManager()
        let directAdapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: credentials,
            bridgeManager: directBridge
        )

        _ = try directAdapter.apply(profile: directProfile)
        XCTAssertTrue(directBridge.events.isEmpty)
    }

    func testNormalizesDeveloperMessagesAndMissingFunctionSchemas() throws {
        let request = """
        {
          "model": "glm-5.2",
          "stream": true,
          "input": [
            {"role": "developer", "content": "Developer policy."},
            {"role": "system", "content": "System policy."},
            {
              "role": "user",
              "content": [
                {"type": "input_image", "image_url": "https://example.invalid/diagram.png"}
              ]
            }
          ],
          "tools": [
            {"type": "function", "name": "missing_parameters"},
            {
              "type": "function",
              "function": {"name": "null_parameters", "parameters": null}
            }
          ]
        }
        """

        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "system")
        let imagePart = try XCTUnwrap(
            (messages[2]["content"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(
            (imagePart["image_url"] as? [String: Any])?["url"] as? String,
            "https://example.invalid/diagram.png"
        )

        let tools = try XCTUnwrap(chat["tools"] as? [[String: Any]])
        for tool in tools {
            let parameters = try XCTUnwrap(
                (tool["function"] as? [String: Any])?["parameters"] as? [String: Any]
            )
            XCTAssertEqual(parameters["type"] as? String, "object")
            XCTAssertNotNil(parameters["properties"] as? [String: Any])
        }
    }

    func testOmitsToolControlsWhenToolsAreEmpty() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "tools": [],
            "tool_choice": "required",
            "parallel_tool_calls": true
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )

        XCTAssertNil(chat["tools"])
        XCTAssertNil(chat["tool_choice"])
        XCTAssertNil(chat["parallel_tool_calls"])
    }

    func testRejectsModelsThatAreNotKnownOpenCodeGoChatModels() throws {
        for model in ["gpt-5.6-luna", "qwen3.8-max", "unknown-model"] {
            let body = try JSONSerialization.data(withJSONObject: ["model": model])
            XCTAssertThrowsError(
                try OpenCodeGoResponsesRequestConverter.convert(responseRequest: body)
            ) { error in
                XCTAssertEqual(error as? OpenCodeGoBridgeError, .unsupportedModel)
            }
        }
    }

    func testSeparatesThinkTagsAcrossBufferedSSEChunks() throws {
        let upstream = """
        data: {"id":"chatcmpl_think","model":"glm-5.2","choices":[{"index":0,"delta":{"content":"Before <th"},"finish_reason":null}]}

        data: {"id":"chatcmpl_think","choices":[{"index":0,"delta":{"content":"ink>private reasoning"},"finish_reason":null}]}

        data: {"id":"chatcmpl_think","choices":[{"index":0,"delta":{"content":"</think> After"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.reasoning_summary_text.delta"))
        XCTAssertTrue(events.contains("private reasoning"))
        XCTAssertTrue(events.contains("Before  After"))
        XCTAssertFalse(events.contains("<think>"))
        XCTAssertFalse(events.contains("</think>"))
    }

    func testTreatsUnclosedThinkTagsAsReasoning() throws {
        let upstream = """
        {"id":"chatcmpl_unclosed","model":"glm-5.2","choices":[{"message":{"role":"assistant","content":"Visible <think>private"},"finish_reason":"stop"}]}
        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))

        XCTAssertTrue(events.contains("event: response.reasoning_summary_text.delta"))
        XCTAssertTrue(events.contains("Visible "))
        XCTAssertTrue(events.contains("private"))
        XCTAssertFalse(events.contains("<think>"))
        XCTAssertFalse(events.contains("</think>"))
    }

    func testAcceptsCompactRoutesAndReturnsTypedErrorsForNonResponsesBodies() throws {
        XCTAssertTrue(OpenCodeGoBridgeRoute.accepts("/v1/responses/compact"))
        XCTAssertTrue(OpenCodeGoBridgeRoute.accepts("/responses/compact"))
        XCTAssertFalse(OpenCodeGoBridgeRoute.accepts("/v1/chat/completions"))
        XCTAssertEqual(URLSessionOpenCodeGoBridgeTransport.upstreamRequestTimeout, 60)

        XCTAssertThrowsError(
            try OpenCodeGoResponsesRequestConverter.convert(
                responseRequest: Data("{\"operation\":\"compact\"}".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? OpenCodeGoBridgeError, .invalidRequest)
        }
        XCTAssertEqual(
            OpenCodeGoBridgeErrorNormalizer.normalize(
                OpenCodeGoBridgeError.invalidRequest
            ).statusCode,
            400
        )
    }

    func testPrepareForUseStartsOnlyForAnActiveBridgeConfiguration() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let configDirectory = directoryURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("config.toml")
        let bridge = FakeBridgeManager()
        let adapter = CodexClientAdapter(
            configURL: configURL,
            credentialStore: FakeCredentialStore(),
            bridgeManager: bridge
        )

        try Data("model_provider = \"all_in_one_openrouter\"\n".utf8).write(to: configURL)
        try adapter.prepareForUse()
        XCTAssertTrue(bridge.events.isEmpty)

        try Data("model_provider = \"all_in_one_opencode_go_bridge\"\n".utf8).write(to: configURL)
        try adapter.prepareForUse()
        XCTAssertEqual(bridge.events, ["ensure"])

        let noOpAdapter: any ClientAdapter = NoopClientAdapter()
        XCTAssertNoThrow(try noOpAdapter.prepareForUse())
    }

    func testConfiguresAcceptedSocketsToSuppressSigPipe() throws {
        var descriptors: [Int32] = [0, 0]
        let created = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        XCTAssertEqual(created, 0)
        defer {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
        }

        XCTAssertTrue(OpenCodeGoBridgeSocketOptions.configureNoSigPipe(on: descriptors[0]))
        var enabled: Int32 = 0
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        let inspected = withUnsafeMutablePointer(to: &enabled) { pointer in
            Darwin.getsockopt(
                descriptors[0],
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                &optionLength
            )
        }
        XCTAssertEqual(inspected, 0)
        XCTAssertEqual(enabled, 1)
    }

    func testCustomToolRoundTripsThroughChatAsCustomToolCall() throws {
        let request = """
        {
          "model": "glm-5.2",
          "tools": [{
            "type": "custom",
            "name": "run_shell",
            "description": "Runs a shell command."
          }]
        }
        """
        let requestConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestConversion.body) as? [String: Any]
        )
        let function = try XCTUnwrap(
            (chat["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any]
        )
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "run_shell")
        XCTAssertEqual(parameters["required"] as? [String], ["input"])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)

        let upstream = """
        {"id":"chatcmpl_custom","choices":[{"message":{"tool_calls":[{"id":"call_shell","type":"function","function":{"name":"run_shell","arguments":"{\\"input\\":\\"pwd\\"}"}}]},"finish_reason":"tool_calls"}]}
        """
        let responseConversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2",
            toolContext: requestConversion.toolContext
        )
        let events = try XCTUnwrap(String(data: responseConversion.sse, encoding: .utf8))
        XCTAssertTrue(events.contains("event: response.custom_tool_call_input.delta"))
        XCTAssertTrue(events.contains("event: response.custom_tool_call_input.done"))
        XCTAssertTrue(events.contains("\"type\":\"custom_tool_call\""))
        XCTAssertTrue(events.contains("\"name\":\"run_shell\""))
        XCTAssertTrue(events.contains("\"input\":\"pwd\""))
        XCTAssertTrue(events.contains("event: response.output_item.done"))
    }

    func testCoalescesFragmentedCustomToolArguments() throws {
        let context = OpenCodeGoToolContext(mappings: [
            OpenCodeGoToolMapping(
                chatName: "write_file",
                responseName: "write_file",
                kind: .custom
            )
        ])
        let upstream = #"""
        data: {"id":"chatcmpl_custom_fragment","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_write","function":{"name":"write_file","arguments":"{\"input\":\"hel"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl_custom_fragment","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"lo\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """#
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            contentType: "text/event-stream",
            fallbackModel: "glm-5.2",
            toolContext: context
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))
        XCTAssertTrue(events.contains("\"input\":\"hello\""))
        XCTAssertTrue(events.contains("event: response.custom_tool_call_input.done"))
    }

    func testFlattensNamespacedToolsAndHashesLongNamesReversibly() throws {
        let longName = String(repeating: "a", count: 80)
        let request: [String: Any] = [
            "model": "glm-5.2",
            "tools": [[
                "type": "custom",
                "namespace": "filesystem",
                "name": "read"
            ], [
                "type": "custom",
                "name": longName
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let first = try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
        let second = try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
        let mappings = first.toolContext.mappings
        let namespaced = try XCTUnwrap(mappings.first { $0.responseName == "read" })
        let long = try XCTUnwrap(mappings.first { $0.responseName == longName })

        XCTAssertEqual(namespaced.chatName, "filesystem__read")
        XCTAssertEqual(namespaced.namespace, "filesystem")
        XCTAssertLessThanOrEqual(long.chatName.count, 64)
        XCTAssertEqual(long.chatName, second.toolContext.mapping(forChatName: long.chatName)?.chatName)
        XCTAssertEqual(first.toolContext.mapping(forChatName: long.chatName)?.responseName, longName)
    }

    func testToolSearchUsesSyntheticTypedToolCall() throws {
        let request = """
        {
          "model": "glm-5.2",
          "tools": [{"type": "tool_search", "namespace": "docs"}]
        }
        """
        let requestConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let mapping = try XCTUnwrap(requestConversion.toolContext.mappings.first)
        XCTAssertEqual(mapping.kind, .toolSearch)
        XCTAssertEqual(mapping.chatName, "docs__docs_search")

        let upstream = """
        {"id":"chatcmpl_search","choices":[{"message":{"tool_calls":[{"id":"call_search","type":"function","function":{"name":"docs__docs_search","arguments":"{\\"input\\":\\"Codex tools\\"}"}}]},"finish_reason":"tool_calls"}]}
        """
        let responseConversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2",
            toolContext: requestConversion.toolContext
        )
        let events = try XCTUnwrap(String(data: responseConversion.sse, encoding: .utf8))
        XCTAssertTrue(events.contains("\"type\":\"tool_search_call\""))
        XCTAssertTrue(events.contains("event: response.tool_search_call_input.done"))
        XCTAssertTrue(events.contains("\"input\":\"Codex tools\""))
    }

    func testCustomToolCallAndOutputHistoryBecomeChatToolMessages() throws {
        let request = """
        {
          "model": "glm-5.2",
          "tools": [{"type": "custom", "name": "execute"}],
          "input": [
            {"type": "custom_tool_call", "call_id": "call_execute", "name": "execute", "input": "echo hello"},
            {"type": "custom_tool_call_output", "call_id": "call_execute", "output": "hello"}
          ]
        }
        """
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        let toolCall = try XCTUnwrap(
            (messages[0]["tool_calls"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(
            ((toolCall["function"] as? [String: Any])?["arguments"] as? String),
            "{\"input\":\"echo hello\"}"
        )
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "call_execute")
        XCTAssertEqual(messages[1]["content"] as? String, "hello")
    }

    func testSystemAndDeveloperMessagesPrecedeCachedToolHistory() throws {
        let cache = OpenCodeGoToolCallCache()
        cache.store(
            responseID: "resp_prior",
            toolCalls: [OpenCodeGoToolCall(id: "call_lookup", name: "lookup", arguments: "{}")]
        )
        let request = """
        {
          "model": "glm-5.2",
          "previous_response_id": "resp_prior",
          "input": [
            {"type": "function_call_output", "call_id": "call_lookup", "output": "result"},
            {"role": "developer", "content": "Developer instructions."},
            {"role": "system", "content": "System instructions."}
          ]
        }
        """
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: Data(request.utf8),
            toolCallCache: cache
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, [
            "system", "system", "assistant", "tool"
        ])
        XCTAssertEqual(messages[2]["tool_calls"] as? [[String: Any]] != nil, true)
        XCTAssertEqual(messages[3]["content"] as? String, "result")
    }

    func testRejectsInvalidCustomToolNamesAndSchemas() throws {
        for tool in [
            ["type": "custom", "name": "   "] as [String: Any],
            ["type": "custom", "name": "valid", "parameters": "not-an-object"] as [String: Any]
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "model": "glm-5.2",
                "tools": [tool]
            ])
            XCTAssertThrowsError(
                try OpenCodeGoResponsesRequestConverter.convert(responseRequest: data)
            ) { error in
                XCTAssertEqual(error as? OpenCodeGoBridgeError, .invalidRequest)
            }
        }
    }

    private func makeProfile(
        presetID: ProviderPresetID,
        model: String? = nil
    ) -> ProviderProfile {
        ProviderProfile(
            name: "Test profile",
            presetID: presetID,
            model: model,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllInOneCodexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}

private final class FakeCredentialStore: CredentialStoring {
    private var credentials: [UUID: Data] = [:]

    func save(_ credential: Data, for profileID: UUID) throws {
        credentials[profileID] = credential
    }

    func read(for profileID: UUID) throws -> Data {
        guard let credential = credentials[profileID] else {
            throw CredentialStoreError.notFound
        }
        return credential
    }

    func delete(for profileID: UUID) throws {
        credentials.removeValue(forKey: profileID)
    }
}

private final class FakeBridgeManager: OpenCodeGoBridgeManaging {
    var events: [String] = []
    var onEnsure: (() throws -> Void)?

    func ensureRunning() throws {
        events.append("ensure")
        try onEnsure?()
    }

    func stop() {
        events.append("stop")
    }
}

private struct NoopClientAdapter: ClientAdapter {
    func preview(profile: ProviderProfile) throws -> SwitchPreview {
        SwitchPreview(original: "", projected: "", summary: "")
    }

    func apply(profile: ProviderProfile) throws -> SwitchReceipt {
        SwitchReceipt(
            backupURL: URL(fileURLWithPath: "/tmp/noop"),
            beforeHash: "",
            afterHash: "",
            timestamp: .distantPast,
            originalConfigExisted: false
        )
    }

    func undo(_ receipt: SwitchReceipt) throws {}
}
