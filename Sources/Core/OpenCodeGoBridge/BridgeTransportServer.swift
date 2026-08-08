import Darwin
import Dispatch
import Foundation

/// Default upstream transport. It is intentionally stateless and does not
/// persist the incoming bearer credential.
public final class URLSessionOpenCodeGoBridgeTransport: OpenCodeGoBridgeTransport, @unchecked Sendable {
    public static let upstreamRequestTimeout: TimeInterval = 60
    public static let upstreamResourceTimeout: TimeInterval = 120

    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    public func execute(_ request: URLRequest) async throws -> OpenCodeGoBridgeTransportResponse {
        let (body, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeGoBridgeError.upstreamUnavailable
        }
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        return OpenCodeGoBridgeTransportResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = upstreamRequestTimeout
        configuration.timeoutIntervalForResource = upstreamResourceTimeout
        return URLSession(configuration: configuration)
    }
}

/// Thread-safe owner of the fixed local listener used by Chat-only models.
public final class OpenCodeGoBridgeManager: OpenCodeGoBridgeManaging, @unchecked Sendable {
    public static let port: UInt16 = 14_556
    public static let baseURL = ProviderCatalog.openCodeGoBridgeBaseURL
    public static let shared = OpenCodeGoBridgeManager()

    private let lock = NSLock()
    private let port: UInt16
    private let transport: any OpenCodeGoBridgeTransport
    private let toolCallCache: OpenCodeGoToolCallCache
    private var server: OpenCodeGoLoopbackHTTPServer?

    public init(
        port: UInt16 = OpenCodeGoBridgeManager.port,
        transport: any OpenCodeGoBridgeTransport = URLSessionOpenCodeGoBridgeTransport(),
        toolCallCache: OpenCodeGoToolCallCache = OpenCodeGoToolCallCache()
    ) {
        self.port = port
        self.transport = transport
        self.toolCallCache = toolCallCache
    }

    public var status: OpenCodeGoBridgeStatus {
        lock.lock()
        defer { lock.unlock() }
        return server == nil ? .stopped : .running
    }

    /// The active listener port. A zero configured port is useful for isolated
    /// loopback tests and is replaced by the kernel-selected port after start.
    public var localPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return server?.localPort
    }

    public func ensureRunning() throws {
        lock.lock()
        defer { lock.unlock() }
        guard server == nil else {
            return
        }

        let handler = OpenCodeGoBridgeRequestHandler(
            transport: transport,
            toolCallCache: toolCallCache
        )
        let candidate = OpenCodeGoLoopbackHTTPServer(
            port: port,
            handler: handler
        )
        do {
            try candidate.start()
            server = candidate
        } catch {
            candidate.stop()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let server = self.server
        self.server = nil
        lock.unlock()
        server?.stop()
    }

    deinit {
        stop()
    }
}

private struct OpenCodeGoBridgeHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct OpenCodeGoBridgeHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func health() -> OpenCodeGoBridgeHTTPResponse {
        OpenCodeGoBridgeHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: Data("{\"status\":\"ok\"}".utf8)
        )
    }

    static func models() -> OpenCodeGoBridgeHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(CodexModelCatalog.bridgeModelListResponse())) ?? Data()
        return OpenCodeGoBridgeHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    static func sse(
        statusCode: Int = 200,
        body: Data
    ) -> OpenCodeGoBridgeHTTPResponse {
        OpenCodeGoBridgeHTTPResponse(
            statusCode: statusCode,
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache"
            ],
            body: body
        )
    }

    static func normalizedError(_ error: Error) -> OpenCodeGoBridgeHTTPResponse {
        let normalized = OpenCodeGoBridgeErrorNormalizer.normalize(error)
        let object: [String: Any] = [
            "error": [
                "code": normalized.code,
                "message": normalized.message,
                "type": "invalid_request_error"
            ]
        ]
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return OpenCodeGoBridgeHTTPResponse(
            statusCode: normalized.statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }
}

enum OpenCodeGoBridgeRoute {
    static let modelListPaths: Set<String> = [
        "/models",
        "/v1/models"
    ]

    static let responsesPaths: Set<String> = [
        "/v1/responses",
        "/responses",
        "/v1/v1/responses",
        "/codex/v1/responses",
        "/v1/responses/compact",
        "/responses/compact"
    ]

    static func accepts(_ path: String) -> Bool {
        responsesPaths.contains(path)
    }

    static func acceptsModelList(_ path: String) -> Bool {
        modelListPaths.contains(path)
    }
}

private final class OpenCodeGoBridgeRequestHandler: @unchecked Sendable {
    private static let upstreamURL = URL(string: "https://opencode.ai/zen/go/v1/chat/completions")!

    private let transport: any OpenCodeGoBridgeTransport
    private let toolCallCache: OpenCodeGoToolCallCache

    init(
        transport: any OpenCodeGoBridgeTransport,
        toolCallCache: OpenCodeGoToolCallCache
    ) {
        self.transport = transport
        self.toolCallCache = toolCallCache
    }

    func handle(
        _ request: OpenCodeGoBridgeHTTPRequest,
        completion: @escaping @Sendable (OpenCodeGoBridgeHTTPResponse) -> Void
    ) {
        if request.method == "GET", request.path == "/health" {
            completion(.health())
            return
        }
        if request.method == "GET", OpenCodeGoBridgeRoute.acceptsModelList(request.path) {
            completion(.models())
            return
        }
        guard request.method == "POST" else {
            completion(
                OpenCodeGoBridgeHTTPResponse(
                    statusCode: 405,
                    headers: ["Content-Type": "application/json; charset=utf-8"],
                    body: Data("{\"error\":{\"code\":\"method_not_allowed\"}}".utf8)
                )
            )
            return
        }
        guard OpenCodeGoBridgeRoute.accepts(request.path) else {
            completion(
                OpenCodeGoBridgeHTTPResponse(
                    statusCode: 404,
                    headers: ["Content-Type": "application/json; charset=utf-8"],
                    body: Data("{\"error\":{\"code\":\"not_found\"}}".utf8)
                )
            )
            return
        }
        if let encoding = request.headers["content-encoding"],
           !encoding.isEmpty,
           encoding.lowercased() != "identity"
        {
            completion(.normalizedError(OpenCodeGoBridgeError.unsupportedContentEncoding))
            return
        }
        guard
            let authorization = request.headers["authorization"],
            authorization.lowercased().hasPrefix("bearer "),
            authorization.dropFirst("bearer ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        else {
            completion(.normalizedError(OpenCodeGoBridgeError.missingAuthorization))
            return
        }

        let converted: OpenCodeGoChatRequestConversion
        do {
            converted = try OpenCodeGoResponsesRequestConverter.convert(
                responseRequest: request.body,
                toolCallCache: toolCallCache
            )
        } catch {
            completion(.normalizedError(error))
            return
        }

        var upstreamRequest = URLRequest(url: Self.upstreamURL)
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.httpBody = converted.body
        upstreamRequest.timeoutInterval = URLSessionOpenCodeGoBridgeTransport.upstreamRequestTimeout
        upstreamRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstreamRequest.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        // This is the Keychain-backed credential supplied by Codex. It is
        // forwarded only to the upstream request and never copied elsewhere.
        upstreamRequest.setValue(authorization, forHTTPHeaderField: "Authorization")

        Task { [transport, toolCallCache] in
            do {
                let upstream = try await transport.execute(upstreamRequest)
                guard (200..<300).contains(upstream.statusCode) else {
                    let normalized = OpenCodeGoBridgeErrorNormalizer.normalize(
                        OpenCodeGoBridgeError.upstreamRejected,
                        upstreamStatusCode: upstream.statusCode
                    )
                    completion(
                        .sse(
                            statusCode: normalized.statusCode,
                            body: OpenCodeGoResponsesEventEncoder.failure(
                                responseID: "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                                model: converted.model,
                                normalizedError: normalized
                            )
                        )
                    )
                    return
                }

                let conversion = try OpenCodeGoChatResponseConverter.convert(
                    chatResponse: upstream.body,
                    contentType: upstream.headers["content-type"],
                    fallbackModel: converted.model,
                    toolContext: converted.toolContext
                )
                toolCallCache.store(
                    responseID: conversion.responseID,
                    toolCalls: conversion.toolCalls,
                    reasoningContent: conversion.reasoningContent
                )
                completion(.sse(body: conversion.sse))
            } catch {
                let normalized = OpenCodeGoBridgeErrorNormalizer.normalize(error)
                completion(
                    .sse(
                        statusCode: normalized.statusCode,
                        body: OpenCodeGoResponsesEventEncoder.failure(
                            responseID: "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                            model: converted.model,
                            normalizedError: normalized
                        )
                    )
                )
            }
        }
    }
}

enum OpenCodeGoBridgeSocketOptions {
    @discardableResult
    static func configureNoSigPipe(on descriptor: Int32) -> Bool {
        var enabled: Int32 = 1
        return Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
    }
}

/// Minimal HTTP/1.1 server restricted to the IPv4 loopback address. Each
/// connection is closed after one request to keep parsing and credential
/// lifetimes bounded.
private final class OpenCodeGoLoopbackHTTPServer: @unchecked Sendable {
    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumBodyBytes = 8 * 1024 * 1024

    private let port: UInt16
    private let handler: OpenCodeGoBridgeRequestHandler
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "com.allinonecodex.bridge.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.allinonecodex.bridge.connection",
        attributes: .concurrent
    )
    private var listeningDescriptor: Int32 = -1
    private var boundPort: UInt16?
    private var isRunning = false

    init(port: UInt16, handler: OpenCodeGoBridgeRequestHandler) {
        self.port = port
        self.handler = handler
    }

    var localPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    func start() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw OpenCodeGoBridgeError.unableToStart
        }

        var reuseAddress: Int32 = 1
        _ = Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: Darwin.inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0 else {
            let bindError = errno
            _ = Darwin.close(descriptor)
            if bindError == EADDRINUSE {
                throw OpenCodeGoBridgeError.portInUse
            }
            throw OpenCodeGoBridgeError.unableToStart
        }

        guard Darwin.listen(descriptor, SOMAXCONN) == 0 else {
            _ = Darwin.close(descriptor)
            throw OpenCodeGoBridgeError.unableToStart
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolvedPort = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &boundAddressLength)
            }
        }
        guard resolvedPort == 0 else {
            _ = Darwin.close(descriptor)
            throw OpenCodeGoBridgeError.unableToStart
        }

        lock.lock()
        listeningDescriptor = descriptor
        boundPort = UInt16(bigEndian: boundAddress.sin_port)
        isRunning = true
        lock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        lock.lock()
        let descriptor = listeningDescriptor
        listeningDescriptor = -1
        boundPort = nil
        isRunning = false
        lock.unlock()

        guard descriptor >= 0 else {
            return
        }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
    }

    deinit {
        stop()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let descriptor = listeningDescriptor
            let running = isRunning
            lock.unlock()
            guard running, descriptor >= 0 else {
                return
            }

            var remoteAddress = sockaddr_storage()
            var remoteAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientDescriptor = withUnsafeMutablePointer(to: &remoteAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(descriptor, $0, &remoteAddressLength)
                }
            }

            if clientDescriptor < 0 {
                if errno == EINTR {
                    continue
                }
                lock.lock()
                let stillRunning = isRunning
                lock.unlock()
                if !stillRunning {
                    return
                }
                continue
            }
            guard OpenCodeGoBridgeSocketOptions.configureNoSigPipe(on: clientDescriptor) else {
                _ = Darwin.close(clientDescriptor)
                continue
            }

            connectionQueue.async { [weak self] in
                self?.serveConnection(clientDescriptor)
            }
        }
    }

    private func serveConnection(_ descriptor: Int32) {
        switch Self.readRequest(from: descriptor) {
        case .success(let request):
            handler.handle(request) { response in
                Self.write(response, to: descriptor)
                _ = Darwin.close(descriptor)
            }
        case .failure(let error):
            Self.write(.normalizedError(error), to: descriptor)
            _ = Darwin.close(descriptor)
        }
    }

    private static func readRequest(
        from descriptor: Int32
    ) -> Result<OpenCodeGoBridgeHTTPRequest, OpenCodeGoBridgeError> {
        var bytes = Data()
        let separator = Data([13, 10, 13, 10])

        while bytes.range(of: separator) == nil {
            guard let received = receive(from: descriptor) else {
                return .failure(.invalidRequest)
            }
            bytes.append(received)
            if bytes.count > maximumHeaderBytes {
                return .failure(.requestTooLarge)
            }
        }

        guard let separatorRange = bytes.range(of: separator) else {
            return .failure(.invalidRequest)
        }
        let headerData = bytes.subdata(in: 0..<separatorRange.lowerBound)
        guard
            let headerText = String(data: headerData, encoding: .utf8),
            let parsedHeader = parseHeader(headerText)
        else {
            return .failure(.invalidRequest)
        }

        let initialBody = bytes.subdata(in: separatorRange.upperBound..<bytes.count)
        guard parsedHeader.method == "POST" else {
            return .success(
                OpenCodeGoBridgeHTTPRequest(
                    method: parsedHeader.method,
                    path: parsedHeader.path,
                    headers: parsedHeader.headers,
                    body: Data()
                )
            )
        }

        if parsedHeader.headers["transfer-encoding"]?
            .lowercased()
            .contains("chunked") == true
        {
            return .failure(.contentLengthRequired)
        }
        if let encoding = parsedHeader.headers["content-encoding"],
           !encoding.isEmpty,
           encoding.lowercased() != "identity"
        {
            return .failure(.unsupportedContentEncoding)
        }
        guard let rawLength = parsedHeader.headers["content-length"] else {
            return .failure(.contentLengthRequired)
        }
        guard let contentLength = Int(rawLength), contentLength >= 0 else {
            return .failure(.invalidContentLength)
        }
        guard contentLength <= maximumBodyBytes else {
            return .failure(.requestTooLarge)
        }

        var body = initialBody
        while body.count < contentLength {
            guard let received = receive(from: descriptor) else {
                return .failure(.invalidRequest)
            }
            body.append(received)
            if body.count > maximumBodyBytes {
                return .failure(.requestTooLarge)
            }
        }
        if body.count > contentLength {
            body = body.subdata(in: 0..<contentLength)
        }
        return .success(
            OpenCodeGoBridgeHTTPRequest(
                method: parsedHeader.method,
                path: parsedHeader.path,
                headers: parsedHeader.headers,
                body: body
            )
        )
    }

    private static func parseHeader(
        _ headerText: String
    ) -> (method: String, path: String, headers: [String: String])? {
        let lines = headerText.components(separatedBy: "\r\n")
        guard
            let requestLine = lines.first,
            requestLine.split(separator: " ", maxSplits: 2).count == 3
        else {
            return nil
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        let method = String(requestParts[0]).uppercased()
        let path = String(requestParts[1].split(separator: "?", maxSplits: 1).first ?? "")

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                continue
            }
            headers[name] = value
        }
        return (method, path, headers)
    }

    private static func receive(from descriptor: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.recv(descriptor, rawBuffer.baseAddress, rawBuffer.count, 0)
        }
        guard count > 0 else {
            return nil
        }
        return Data(buffer.prefix(Int(count)))
    }

    private static func write(
        _ response: OpenCodeGoBridgeHTTPResponse,
        to descriptor: Int32
    ) {
        let statusText: String
        switch response.statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 411: statusText = "Length Required"
        case 413: statusText = "Payload Too Large"
        case 415: statusText = "Unsupported Media Type"
        case 429: statusText = "Too Many Requests"
        case 502: statusText = "Bad Gateway"
        case 503: statusText = "Service Unavailable"
        case 504: statusText = "Gateway Timeout"
        default: statusText = "Internal Server Error"
        }

        var headerText = "HTTP/1.1 \(response.statusCode) \(statusText)\r\n"
        for (name, value) in response.headers {
            headerText += "\(name): \(value)\r\n"
        }
        headerText += "Content-Length: \(response.body.count)\r\n"
        headerText += "Connection: close\r\n\r\n"

        _ = sendAll(Data(headerText.utf8), to: descriptor)
        _ = sendAll(response.body, to: descriptor)
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else {
                return true
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let sent = Darwin.send(descriptor, pointer, remaining, 0)
                if sent > 0 {
                    pointer = pointer.advanced(by: sent)
                    remaining -= sent
                    continue
                }
                if sent == -1, errno == EINTR {
                    continue
                }
                return false
            }
            return true
        }
    }
}
