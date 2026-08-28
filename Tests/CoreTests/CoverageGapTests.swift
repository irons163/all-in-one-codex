import Foundation
import XCTest

@testable import AllInOneCodex

final class CoverageGapTests: XCTestCase {
    func testLocalizedErrorDescriptionsCoverEveryCase() {
        let switchErrors: [CodexSwitchError] = [
            .invalidProfile,
            .malformedManagedMarkers,
            .misplacedActiveMarker,
            .missingCredential,
            .unreadableConfiguration,
            .unableToWriteConfiguration,
            .backupUnavailable,
            .backupIntegrityConflict,
            .configurationChanged,
            .modelCatalogChanged,
            .foreignModelCatalogPointer,
            .unsafeBackupPath,
            .invalidConfigurationBackup,
            .configurationBackupTooLarge,
            .foreignOpenAIBaseURL
        ]
        for error in switchErrors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }

        let catalogErrors: [CodexModelCatalogError] = [
            .emptyModels,
            .tooManyModels,
            .duplicateModel,
            .invalidModelIdentifier,
            .invalidSchema,
            .catalogTooLarge,
            .unreadableCatalog,
            .unsafeCatalogPath
        ]
        for error in catalogErrors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }

        let credentialErrors: [CredentialStoreError] = [
            .emptyCredential, .notFound, .unavailable
        ]
        for error in credentialErrors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }

        let routingErrors: [ProviderRoutingError] = [
            .invalidModel,
            .unknownOpenCodeGoModel,
            .unsupportedOpenCodeGoWireAPI(.anthropicMessages),
            .unsupportedOpenCodeGoWireAPI(.chatCompletions)
        ]
        for error in routingErrors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }

        let journalErrors: [SwitchReceiptRepositoryError] = [
            .unableToWriteJournal, .unableToDeleteJournal
        ]
        for error in journalErrors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }

        let bridgeErrors: [OpenCodeGoBridgeError] = [
            .portInUse,
            .unableToStart,
            .requestTooLarge,
            .contentLengthRequired,
            .invalidContentLength,
            .unsupportedContentEncoding,
            .invalidRequest,
            .unsupportedModel,
            .missingAuthorization,
            .missingProviderCredential,
            .sessionRequestLimitReached,
            .upstreamUnavailable,
            .upstreamRejected,
            .invalidUpstreamResponse
        ]
        for error in bridgeErrors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }
    }

    func testThinkingProfileInfersVendorAliasesAndUnknownModels() {
        XCTAssertEqual(
            OpenCodeGoThinkingProfile.infer(model: "Moonshot-Kimi")?.thinkingParam,
            .thinking
        )
        XCTAssertEqual(
            OpenCodeGoThinkingProfile.infer(model: "zhipu-glm")?.thinkingParam,
            .thinking
        )
        XCTAssertTrue(OpenCodeGoThinkingProfile.infer(model: "mimo-v2.5")?.supportsThinking ?? false)
        XCTAssertNil(OpenCodeGoThinkingProfile.infer(model: "grok-4.5"))
        XCTAssertNil(OpenCodeGoThinkingProfile.infer(model: "gpt-5.6-luna"))
        XCTAssertTrue(
            OpenCodeGoThinkingProfile.infer(model: "deepseek-v4-pro")?
                .requiresToolCallReasoningPlaceholder ?? false
        )
    }

    func testAppLanguageAndAppearanceLabelsAndFallbackLookup() {
        for language in AppLanguage.allCases {
            XCTAssertFalse(language.displayName.isEmpty)
            XCTAssertEqual(language.locale.identifier, language.rawValue)
        }
        for appearance in AppAppearance.allCases {
            XCTAssertFalse(appearance.displayName.isEmpty)
        }
        XCTAssertEqual(AppLanguage.resolve(from: Locale(identifier: "zh_TW")), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(from: Locale(identifier: "zh_CN")), .simplifiedChinese)
        _ = AppLanguage.current
        XCTAssertFalse(L10n.tr("%@ 失敗：%@", "Apply", "missing credential").isEmpty)
        XCTAssertEqual(
            AppLanguage.korean.localizedString(forKey: "a-key-that-does-not-exist"),
            "a-key-that-does-not-exist"
        )
    }

    func testKeychainCredentialStoreRoundTripsAndRejectsEmptyValues() throws {
        let store = KeychainCredentialStore()
        let profileID = UUID()
        defer { try? store.delete(for: profileID) }

        XCTAssertThrowsError(try store.save(Data(), for: profileID)) { error in
            XCTAssertEqual(error as? CredentialStoreError, .emptyCredential)
        }
        XCTAssertThrowsError(try store.save("", for: profileID)) { error in
            XCTAssertEqual(error as? CredentialStoreError, .emptyCredential)
        }
        XCTAssertFalse(store.contains(for: profileID))
        XCTAssertThrowsError(try store.read(for: profileID)) { error in
            XCTAssertEqual(error as? CredentialStoreError, .notFound)
        }

        try store.save("test-key-\(profileID.uuidString)", for: profileID)
        XCTAssertTrue(store.contains(for: profileID))
        XCTAssertEqual(
            String(data: try store.read(for: profileID), encoding: .utf8),
            "test-key-\(profileID.uuidString)"
        )

        try store.save(Data("rotated-key".utf8), for: profileID)
        XCTAssertEqual(try store.read(for: profileID), Data("rotated-key".utf8))

        try store.delete(for: profileID)
        XCTAssertFalse(store.contains(for: profileID))
        try store.delete(for: profileID)
    }

    func testCredentialProtocolContainsUsesRead() throws {
        let store = InMemoryCredentialStore()
        let profileID = UUID()
        XCTAssertFalse(store.contains(for: profileID))
        try store.save(Data("abc".utf8), for: profileID)
        XCTAssertTrue(store.contains(for: profileID))
        try store.save(Data(), for: profileID)
        XCTAssertFalse(store.contains(for: profileID))
    }

    func testIncrementalSSEParserFinishFlushesTrailingAndInvalidPayloads() throws {
        var complete = OpenCodeGoIncrementalChatSSEParser()
        XCTAssertTrue(try complete.push(Data()).isEmpty)
        let trailing = try complete.finish()
        XCTAssertTrue(trailing.isEmpty)

        var parser = OpenCodeGoIncrementalChatSSEParser()
        XCTAssertTrue(try parser.push(Data("data: {\"ok\":true}".utf8)).isEmpty)
        let finished = try parser.finish()
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?["ok"] as? Bool, true)

        var done = OpenCodeGoIncrementalChatSSEParser()
        XCTAssertTrue(try done.push(Data("data: [DONE]".utf8)).isEmpty)
        XCTAssertTrue(try done.finish().isEmpty)

        var ignored = OpenCodeGoIncrementalChatSSEParser()
        XCTAssertTrue(try ignored.push(Data("retry: 1000".utf8)).isEmpty)
        XCTAssertTrue(try ignored.finish().isEmpty)

        var invalid = OpenCodeGoIncrementalChatSSEParser()
        XCTAssertThrowsError(try invalid.finishPayload("data: [1]")) { error in
            XCTAssertEqual(error as? OpenCodeGoBridgeError, .invalidUpstreamResponse)
        }
    }

    func testStreamingBridgeStripsLifecycleAndRejectsInvalidUTF8() throws {
        let created = try OpenCodeGoStreamingChatBridge.earlyLifecycleSSE(
            responseID: "resp_lifecycle",
            model: "glm-5.2",
            createdAt: 1_700_000_000
        )
        let stripped = OpenCodeGoStreamingChatBridge.stripLeadingLifecycle(from: created)
        XCTAssertFalse(String(data: stripped, encoding: .utf8)?.contains("response.created") ?? true)

        let unrelated = Data("event: response.output_text.delta\ndata: {}\n\n".utf8)
        XCTAssertEqual(
            OpenCodeGoStreamingChatBridge.stripLeadingLifecycle(from: unrelated),
            unrelated
        )

        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
        XCTAssertEqual(
            OpenCodeGoStreamingChatBridge.stripLeadingLifecycle(from: invalidUTF8),
            invalidUTF8
        )
    }

    func testConvertsCompactionTriggerInvalidRoleAndStructuredToolOutput() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "input": [
                [
                    "type": "function_call",
                    "call_id": "call_lookup",
                    "name": "lookup",
                    "arguments": "{}"
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_lookup",
                    "output": [
                        ["text": "alpha"],
                        ["text": "beta"]
                    ]
                ],
                ["type": "compaction_trigger"],
                [
                    "role": "assistant",
                    "content": "Continuing.",
                    "reasoning": "prior plan"
                ]
            ]
        ]
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(
            messages.map { $0["role"] as? String },
            ["assistant", "tool", "user", "assistant"]
        )
        XCTAssertEqual(messages[1]["content"] as? String, "alphabeta")
        XCTAssertTrue((messages[2]["content"] as? String)?.contains("continuation summary") ?? false)
        XCTAssertEqual(messages[3]["reasoning_content"] as? String, "prior plan")

        let numericOutput: [String: Any] = [
            "model": "glm-5.2",
            "input": [
                [
                    "type": "function_call",
                    "call_id": "call_num",
                    "name": "count",
                    "arguments": "{}"
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_num",
                    "output": 42
                ]
            ]
        ]
        let numeric = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: numericOutput)
        )
        let numericChat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: numeric.body) as? [String: Any]
        )
        let numericMessages = try XCTUnwrap(numericChat["messages"] as? [[String: Any]])
        XCTAssertEqual(numericMessages.last?["content"] as? String, "42")

        XCTAssertThrowsError(
            try OpenCodeGoResponsesRequestConverter.convert(
                responseRequest: JSONSerialization.data(withJSONObject: [
                    "model": "glm-5.2",
                    "input": [["role": "narrator", "content": "nope"]]
                ])
            )
        ) { error in
            XCTAssertEqual(error as? OpenCodeGoBridgeError, .invalidRequest)
        }

        XCTAssertThrowsError(
            try OpenCodeGoResponsesRequestConverter.convert(
                responseRequest: JSONSerialization.data(withJSONObject: [
                    "model": "glm-5.2",
                    "input": [["type": "function_call_output", "output": "missing id"]]
                ])
            )
        ) { error in
            XCTAssertEqual(error as? OpenCodeGoBridgeError, .invalidRequest)
        }
    }

    func testAttachesPendingReasoningToPreviousAssistantAndMergesDuplicates() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "input": [
                ["role": "assistant", "content": "First look."],
                [
                    "type": "reasoning",
                    "summary": [[
                        "type": "summary_text",
                        "text": "Inspect the repo first."
                    ]]
                ],
                [
                    "type": "reasoning",
                    "summary": [[
                        "type": "summary_text",
                        "text": "Then update the goal."
                    ]]
                ],
                ["role": "user", "content": "go"]
            ]
        ]
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["reasoning_content"] as? String, """
        Inspect the repo first.

        Then update the goal.
        """)
    }

    func testDeepSeekThinkingSanitizesForcedToolChoiceAndDropsJSONObjectFormat() throws {
        let request: [String: Any] = [
            "model": "deepseek-v4-flash",
            "reasoning": ["effort": "high"],
            "response_format": ["type": "json_object"],
            "tool_choice": [
                "type": "function",
                "function": ["name": "lookup_weather"]
            ],
            "parallel_tool_calls": true,
            "input": [["role": "user", "content": "weather"]],
            "tools": [[
                "type": "function",
                "name": "lookup_weather",
                "parameters": ["type": "object", "properties": [:]]
            ]]
        ]
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        XCTAssertEqual(chat["tool_choice"] as? String, "auto")
        XCTAssertNil(chat["parallel_tool_calls"])
        XCTAssertNil(chat["response_format"])
        XCTAssertEqual((chat["thinking"] as? [String: Any])?["type"] as? String, "enabled")

        let disabled: [String: Any] = [
            "model": "deepseek-v4-flash",
            "reasoning": ["effort": "none"],
            "tool_choice": "required",
            "input": [["role": "user", "content": "hi"]],
            "tools": [[
                "type": "function",
                "name": "lookup_weather",
                "parameters": ["type": "object", "properties": [:]]
            ]]
        ]
        let disabledConversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: disabled)
        )
        let disabledChat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: disabledConversion.body) as? [String: Any]
        )
        XCTAssertEqual((disabledChat["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual(disabledChat["tool_choice"] as? String, "required")
    }

    func testGLMForwardsResponseFormatAndNamedToolChoice() throws {
        let request: [String: Any] = [
            "model": "glm-5.2",
            "response_format": ["type": "json_object"],
            "tool_choice": ["name": "lookup_weather"],
            "input": [["role": "user", "content": "weather"]],
            "tools": [[
                "type": "function",
                "name": "lookup_weather",
                "parameters": ["type": "object"]
            ]]
        ]
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        XCTAssertEqual(
            (chat["response_format"] as? [String: Any])?["type"] as? String,
            "json_object"
        )
        let toolChoice = try XCTUnwrap(chat["tool_choice"] as? [String: Any])
        XCTAssertEqual(
            (toolChoice["function"] as? [String: Any])?["name"] as? String,
            "lookup_weather"
        )

                XCTAssertThrowsError(
            try OpenCodeGoResponsesRequestConverter.convert(
                responseRequest: JSONSerialization.data(withJSONObject: [
                    "model": "glm-5.2",
                    "tool_choice": 12,
                    "input": [["role": "user", "content": "hi"]],
                    "tools": [[
                        "type": "function",
                        "name": "lookup_weather",
                        "parameters": ["type": "object"]
                    ]]
                ])
            )
        ) { error in
            XCTAssertEqual(error as? OpenCodeGoBridgeError, .invalidRequest)
        }
    }

    func testGrokForwardsResponseFormatBecauseItIsNotAThinkingModel() throws {
        let request: [String: Any] = [
            "model": "grok-4.5",
            "response_format": ["type": "text"],
            "input": [["role": "user", "content": "hi"]]
        ]
        let conversion = try OpenCodeGoResponsesRequestConverter.convert(
            responseRequest: JSONSerialization.data(withJSONObject: request)
        )
        let chat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conversion.body) as? [String: Any]
        )
        XCTAssertEqual(
            (chat["response_format"] as? [String: Any])?["type"] as? String,
            "text"
        )
    }

    func testNormalizerClassifiesRemainingUpstreamMarkersWithoutLeakingBodies() {
        let thinking = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 400,
            upstreamErrorBody: Data(
                """
                {"error":{"message":"thinking mode does not support this tool_choice","code":"invalid_request_error"}}
                """.utf8
            )
        )
        XCTAssertEqual(thinking.code, "upstream_thinking_tool_choice_unsupported")

        let format = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 400,
            upstreamErrorBody: Data(
                """
                {"error":{"message":"response_format json_object is not allowed"}}
                """.utf8
            )
        )
        XCTAssertEqual(format.code, "upstream_response_format_unsupported")

        let additional = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 400,
            upstreamErrorBody: Data(
                """
                {"error":{"message":"additional property tools is not permitted"}}
                """.utf8
            )
        )
        XCTAssertEqual(additional.code, "upstream_unsupported_parameter_or_tool_schema")

        let generic = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 400,
            upstreamErrorBody: Data(
                """
                {"error":{"message":"something else went wrong"}}
                """.utf8
            )
        )
        XCTAssertEqual(generic.code, "upstream_invalid_request")
        XCTAssertFalse(generic.message.contains("something else"))

        let oversized = Data(repeating: 0x61, count: 70_000)
        let opaque = OpenCodeGoBridgeErrorNormalizer.normalize(
            OpenCodeGoBridgeError.upstreamRejected,
            upstreamStatusCode: 400,
            upstreamErrorBody: oversized
        )
        XCTAssertEqual(opaque.code, "upstream_invalid_request_opaque_http_400")
    }

    func testChatConverterAcceptsArrayContentPartsAndPreferredResponseIDs() throws {
        let upstream = """
        {
          "id": "chatcmpl_parts",
          "model": "glm-5.2",
          "choices": [{
            "message": {
              "role": "assistant",
              "content": [
                {"text": "alpha"},
                {"content": "beta"},
                {"value": "gamma"}
              ]
            },
            "finish_reason": "stop"
          }],
          "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7}
        }
        """
        let conversion = try OpenCodeGoChatResponseConverter.convert(
            chatResponse: Data(upstream.utf8),
            fallbackModel: "glm-5.2",
            preferredResponseID: "resp_preferred"
        )
        let events = try XCTUnwrap(String(data: conversion.sse, encoding: .utf8))
        XCTAssertTrue(events.contains("alphabeta gamma") || events.contains("alphabetagamma"))
        XCTAssertTrue(events.contains("resp_preferred"))
        XCTAssertTrue(events.contains("input_tokens") || events.contains("\"input_tokens\":3"))
    }

    func testModelCatalogRejectsUnsafeIdentifiersAndUnreadableSchema() throws {
        XCTAssertThrowsError(
            try CodexModelCatalog.make(
                for: ProviderProfile(
                    name: "Bad",
                    presetID: .openRouter,
                    model: "not a valid id!!!"
                )
            )
        ) { error in
            XCTAssertEqual(error as? CodexModelCatalogError, .invalidModelIdentifier)
        }

        XCTAssertThrowsError(
            try CodexModelCatalog.decodeValidated(from: Data("{}".utf8))
        ) { error in
            XCTAssertEqual(error as? CodexModelCatalogError, .unreadableCatalog)
        }

        XCTAssertThrowsError(
            try CodexModelCatalog.decodeValidated(from: Data(#"{"models":[]}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? CodexModelCatalogError, .emptyModels)
        }
    }

    func testProviderRouteRejectsEmptyAndUnknownOpenCodeGoModels() {
        XCTAssertThrowsError(
            try ProviderCatalog.route(
                for: ProviderProfile(name: "Empty", presetID: .openCodeGo, model: "   ")
            )
        ) { error in
            XCTAssertEqual(error as? ProviderRoutingError, .invalidModel)
        }
        XCTAssertThrowsError(
            try ProviderCatalog.route(
                for: ProviderProfile(
                    name: "Unknown",
                    presetID: .openCodeGo,
                    model: "not-a-real-model"
                )
            )
        ) { error in
            XCTAssertEqual(error as? ProviderRoutingError, .unknownOpenCodeGoModel)
        }
    }

    func testLoopbackHealthMethodAndUnknownPathPlusUpstreamRejectionDiagnostics() async throws {
        let longMessage = String(repeating: "unsupported tool schema ", count: 40)
        let transport = StubBridgeTransport(
            response: OpenCodeGoBridgeTransportResponse(
                statusCode: 400,
                headers: ["content-type": "application/json"],
                body: Data(
                    """
                    {"error":{"message":"\(longMessage)"}}
                    """.utf8
                )
            )
        )
        let bridge = OpenCodeGoBridgeManager(port: 0, transport: transport)
        let profile = ProviderProfile(
            name: "Diagnostics",
            presetID: .openCodeGo,
            model: "glm-5.2",
            preserveSessions: true
        )
        bridge.configurePreservingSessions(
            route: try ProviderCatalog.route(for: profile),
            credential: Data("diag-key".utf8)
        )
        try bridge.ensureRunning()
        defer { bridge.stop() }
        let port = try XCTUnwrap(bridge.localPort)

        let healthURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/health"))
        let (healthBody, healthResponse) = try await URLSession.shared.data(from: healthURL)
        let healthHTTP = try XCTUnwrap(healthResponse as? HTTPURLResponse)
        XCTAssertEqual(healthHTTP.statusCode, 200)
        XCTAssertTrue(String(data: healthBody, encoding: .utf8)?.contains("\"ok\"") ?? false)

        var put = URLRequest(url: healthURL)
        put.httpMethod = "PUT"
        let (_, putResponse) = try await URLSession.shared.data(for: put)
        XCTAssertEqual((putResponse as? HTTPURLResponse)?.statusCode, 405)

        let unknownURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/not-a-route"))
        var unknown = URLRequest(url: unknownURL)
        unknown.httpMethod = "POST"
        unknown.httpBody = Data("{}".utf8)
        unknown.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, unknownResponse) = try await URLSession.shared.data(for: unknown)
        XCTAssertEqual((unknownResponse as? HTTPURLResponse)?.statusCode, 404)

        let responsesURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/responses"))
        var rejected = URLRequest(url: responsesURL)
        rejected.httpMethod = "POST"
        rejected.httpBody = Data(#"{"model":"glm-5.2","input":[{"role":"user","content":"hello"}]}"#.utf8)
        rejected.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rejected.setValue("Bearer inbound-oauth-must-not-forward", forHTTPHeaderField: "Authorization")
        let (rejectedBody, rejectedResponse) = try await URLSession.shared.data(for: rejected)
        XCTAssertEqual((rejectedResponse as? HTTPURLResponse)?.statusCode, 400)
        let sse = try XCTUnwrap(String(data: rejectedBody, encoding: .utf8))
        XCTAssertTrue(sse.contains("response.failed") || sse.contains("unsupported"))

        let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("AllInOneCodex", isDirectory: true)
            .appendingPathComponent("bridge-upstream-rejections.jsonl")
        if let logURL, FileManager.default.fileExists(atPath: logURL.path) {
            let log = try String(contentsOf: logURL, encoding: .utf8)
            XCTAssertTrue(log.contains("glm-5.2"))
            XCTAssertTrue(log.contains("upstream_status"))
        }
    }

    func testPreserveResponsesLoopbackNormalizesUpstreamRejection() async throws {
        let transport = StubBridgeTransport(
            response: OpenCodeGoBridgeTransportResponse(
                statusCode: 400,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":{"message":"unknown field output"}}"#.utf8)
            )
        )
        let bridge = OpenCodeGoBridgeManager(port: 0, transport: transport)
        let profile = ProviderProfile(
            name: "Passthrough",
            presetID: .openCodeGo,
            model: "gpt-5.6-luna",
            preserveSessions: true
        )
        bridge.configurePreservingSessions(
            route: try ProviderCatalog.route(for: profile),
            credential: Data("luna-key".utf8)
        )
        try bridge.ensureRunning()
        defer { bridge.stop() }

        let port = try XCTUnwrap(bridge.localPort)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/responses"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"gpt-5.6-luna","input":"hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer inbound-oauth-must-not-forward", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "upstream_unsupported_parameter_or_tool_schema")
    }

    func testDefaultClientAdapterBridgeStatusIsStopped() {
        XCTAssertEqual(NoopCoverageClientAdapter().bridgeStatus, .stopped)
        XCTAssertNoThrow(try NoopCoverageClientAdapter().prepareForUse())
        XCTAssertEqual(DefaultStatusBridgeManager().status, .stopped)
    }

    func testToolCallCacheExposesStoredCalls() {
        let cache = OpenCodeGoToolCallCache()
        XCTAssertNil(cache.toolCalls(for: "missing"))
        cache.store(
            responseID: "resp_cache",
            toolCalls: [OpenCodeGoToolCall(id: "call_1", name: "lookup", arguments: "{}")]
        )
        XCTAssertEqual(cache.toolCalls(for: "resp_cache")?.count, 1)
    }

    func testCodexClientAdapterDefaultURLsPointAtHomeCodex() {
        XCTAssertTrue(CodexClientAdapter.defaultConfigURL.path.hasSuffix("/.codex/config.toml"))
        XCTAssertTrue(
            CodexClientAdapter.defaultCatalogURL.path
                .hasSuffix("/.codex/\(CodexModelCatalog.filename)")
        )
    }
}

private extension OpenCodeGoIncrementalChatSSEParser {
    mutating func finishPayload(_ trailing: String) throws -> [[String: Any]] {
        _ = try push(Data(trailing.utf8))
        return try finish()
    }
}

private final class InMemoryCredentialStore: CredentialStoring {
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

private final class StubBridgeTransport: OpenCodeGoBridgeTransport, @unchecked Sendable {
    private let response: OpenCodeGoBridgeTransportResponse

    init(response: OpenCodeGoBridgeTransportResponse) {
        self.response = response
    }

    func execute(_ request: URLRequest) async throws -> OpenCodeGoBridgeTransportResponse {
        response
    }
}

private final class DefaultStatusBridgeManager: OpenCodeGoBridgeManaging {
    func ensureRunning() throws {}
    func stop() {}
}

private struct NoopCoverageClientAdapter: ClientAdapter {
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
