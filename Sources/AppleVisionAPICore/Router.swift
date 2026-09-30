import Foundation
import ImageIO

public enum ModelAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

public struct ModelOutput: Equatable, Sendable {
    public var text: String
    public var usage: OpenAIEncoding.Usage

    public init(text: String, usage: OpenAIEncoding.Usage) {
        self.text = text
        self.usage = usage
    }
}

public enum ModelStreamEvent: Equatable, Sendable {
    case delta(String)
    case usage(OpenAIEncoding.Usage)
}

/// The on-device model, behind a protocol so routing can be tested without Apple Intelligence.
/// Implementations throw `APIError` for failures the client should see.
public protocol ModelBackend: Sendable {
    func availability() -> ModelAvailability
    func respond(to request: ChatRequest, imageData: Data?) async throws -> ModelOutput
    func stream(_ request: ChatRequest, imageData: Data?) -> AsyncThrowingStream<ModelStreamEvent, any Error>
}

public protocol ResponseWriter: Sendable {
    func write(_ data: Data) async throws
}

public struct Router: Sendable {
    public let config: ServerConfig
    public let backend: any ModelBackend

    public init(config: ServerConfig, backend: any ModelBackend) {
        self.config = config
        self.backend = backend
    }

    /// Handles one request and returns the HTTP status sent (for logging).
    @discardableResult
    public func handle(_ request: HTTPRequest, peerIsLoopback: Bool, writer: some ResponseWriter) async -> Int {
        let response: HTTPResponse
        switch request.path {
        case "/health":
            response = request.method == "GET" ? health() : methodNotAllowed("GET")
        case "/v1/models", "/models":
            if let denied = authorize(request) { response = denied }
            else { response = request.method == "GET" ? .json(200, OpenAIEncoding.models()) : methodNotAllowed("GET") }
        case "/v1/chat/completions", "/chat/completions":
            if let denied = authorize(request) { response = denied }
            else if request.method != "POST" { response = methodNotAllowed("POST") }
            else { return await chatCompletion(request, peerIsLoopback: peerIsLoopback, writer: writer) }
        default:
            response = errorResponse(APIError(status: 404, message: "unknown endpoint \(request.path)", type: "invalid_request_error", code: "not_found"))
        }
        try? await writer.write(response.serialized())
        return response.status
    }

    // MARK: - Endpoints

    private func health() -> HTTPResponse {
        switch backend.availability() {
        case .available:
            return .json(200, Data(#"{"status":"ok","model":"\#(modelID)"}"#.utf8))
        case .unavailable(let reason):
            let body = OpenAIEncoding.encode(["status": "unavailable", "model": modelID, "reason": reason])
            return .json(503, body)
        }
    }

    private func chatCompletion(_ request: HTTPRequest, peerIsLoopback: Bool, writer: some ResponseWriter) async -> Int {
        do {
            let chat = try ChatRequestParser.parse(request.body)
            let imageData = try loadImage(chat.image, peerIsLoopback: peerIsLoopback)
            if case .unavailable(let reason) = backend.availability() {
                throw APIError(status: 503, message: "the on-device model is unavailable: \(reason)", type: "server_error", code: "model_unavailable")
            }
            return chat.stream
                ? try await streamCompletion(chat, imageData: imageData, writer: writer)
                : try await singleCompletion(chat, imageData: imageData, writer: writer)
        } catch let error as APIError {
            let response = errorResponse(error)
            try? await writer.write(response.serialized())
            return response.status
        } catch {
            let response = errorResponse(APIError(status: 500, message: "generation failed: \(error.localizedDescription)", type: "server_error"))
            try? await writer.write(response.serialized())
            return response.status
        }
    }

    private func singleCompletion(_ chat: ChatRequest, imageData: Data?, writer: some ResponseWriter) async throws -> Int {
        let output = try await backend.respond(to: chat, imageData: imageData)
        let body = OpenAIEncoding.completion(id: Self.completionID(), created: Self.now(), content: output.text, usage: output.usage)
        try await writer.write(HTTPResponse.json(200, body).serialized())
        return 200
    }

    private func streamCompletion(_ chat: ChatRequest, imageData: Data?, writer: some ResponseWriter) async throws -> Int {
        var events = backend.stream(chat, imageData: imageData).makeAsyncIterator()
        // Wait for the first event before committing to a 200, so early failures
        // (guardrails, context size, …) still get a proper error status.
        let first = try await events.next()

        let id = Self.completionID(), created = Self.now()
        try await writer.write(HTTPResponse.eventStreamHead)
        try await writer.write(OpenAIEncoding.event(OpenAIEncoding.chunk(id: id, created: created, role: "assistant", content: "")))

        var usage: OpenAIEncoding.Usage?
        var pending = first
        do {
            while let event = pending {
                switch event {
                case .delta(let text) where !text.isEmpty:
                    try await writer.write(OpenAIEncoding.event(OpenAIEncoding.chunk(id: id, created: created, content: text)))
                case .delta:
                    break
                case .usage(let value):
                    usage = value
                }
                pending = try await events.next()
            }
        } catch {
            // Headers are already sent: report the failure as a final event, then end the stream.
            let apiError = error as? APIError ?? APIError(status: 500, message: "generation failed: \(error.localizedDescription)", type: "server_error")
            try? await writer.write(OpenAIEncoding.event(OpenAIEncoding.error(apiError)))
            try? await writer.write(OpenAIEncoding.done)
            return 200
        }

        try await writer.write(OpenAIEncoding.event(OpenAIEncoding.chunk(id: id, created: created, finishReason: "stop")))
        if chat.includeUsageInStream {
            let final = usage ?? OpenAIEncoding.Usage(promptTokens: 0, completionTokens: 0)
            try await writer.write(OpenAIEncoding.event(OpenAIEncoding.usageChunk(id: id, created: created, usage: final)))
        }
        try await writer.write(OpenAIEncoding.done)
        return 200
    }

    // MARK: - Helpers

    private func loadImage(_ input: ImageInput?, peerIsLoopback: Bool) throws(APIError) -> Data? {
        let data: Data
        switch input {
        case nil:
            return nil
        case .data(let bytes):
            data = bytes
        case .file(let path):
            guard config.allowLocalFiles, peerIsLoopback else {
                throw APIError(status: 403,
                               message: "local file paths are disabled; send the image as a data: URI (file paths need --allow-local-files and a client on the same Mac)",
                               type: "invalid_request_error", code: "local_files_disabled")
            }
            guard let bytes = FileManager.default.contents(atPath: path) else {
                throw .invalidRequest("could not read the image file", code: "invalid_image")
            }
            data = bytes
        }
        guard Self.isDecodableImage(data) else {
            throw .invalidRequest("the image could not be decoded (use JPEG, PNG, HEIC, GIF, TIFF or WebP)", code: "invalid_image")
        }
        return data
    }

    public static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private func authorize(_ request: HTTPRequest) -> HTTPResponse? {
        guard let key = config.apiKey else { return nil }
        let header = request.header("authorization") ?? ""
        let prefix = "bearer "
        if header.lowercased().hasPrefix(prefix), constantTimeEquals(String(header.dropFirst(prefix.count)), key) {
            return nil
        }
        return errorResponse(APIError(status: 401, message: "missing or invalid API key", type: "invalid_request_error", code: "invalid_api_key"),
                             headers: [("WWW-Authenticate", "Bearer")])
    }

    private func methodNotAllowed(_ allowed: String) -> HTTPResponse {
        errorResponse(APIError(status: 405, message: "method not allowed; use \(allowed)", type: "invalid_request_error", code: "method_not_allowed"),
                      headers: [("Allow", allowed)])
    }

    private func errorResponse(_ error: APIError, headers: [(String, String)] = []) -> HTTPResponse {
        .json(error.status, OpenAIEncoding.error(error), headers: headers)
    }

    static func completionID() -> String { "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased() }
    static func now() -> Int { Int(Date().timeIntervalSince1970) }
}

/// Compares secrets without an early exit, so response timing doesn't reveal how much matched.
public func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var difference = UInt8(truncatingIfNeeded: x.count ^ y.count)
    for i in 0..<max(x.count, y.count) {
        difference |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
    }
    return difference == 0
}
