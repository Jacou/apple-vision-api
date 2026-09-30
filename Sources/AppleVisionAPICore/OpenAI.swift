import Foundation

public let modelID = "apple-foundation-vision"

/// An error returned to the client in OpenAI's error format.
public struct APIError: Error, Equatable, Sendable {
    public let status: Int
    public let message: String
    public let type: String
    public let code: String?
    public let param: String?

    public init(status: Int, message: String, type: String, code: String? = nil, param: String? = nil) {
        self.status = status
        self.message = message
        self.type = type
        self.code = code
        self.param = param
    }

    public static func invalidRequest(_ message: String, code: String? = nil, param: String? = nil) -> APIError {
        APIError(status: 400, message: message, type: "invalid_request_error", code: code, param: param)
    }
}

public enum ImageInput: Equatable, Sendable {
    case data(Data)
    case file(String)
}

/// A chat completion request, reduced to what the on-device model can use.
public struct ChatRequest: Equatable, Sendable {
    /// System and developer messages, passed to the model as instructions.
    public var instructions: String?
    /// The latest user message, preceded by earlier turns when there are any.
    public var prompt: String
    /// The most recent image in the conversation.
    public var image: ImageInput?
    public var stream = false
    public var includeUsageInStream = false
    public var temperature: Double?
    public var maxTokens: Int?

    public static let defaultImagePrompt = "Describe this image."
}

public enum ChatRequestParser {
    public static func parse(_ body: Data) throws(APIError) -> ChatRequest {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw APIError.invalidRequest("the request body must be a JSON object")
            }
            object = parsed
        } catch let error as APIError {
            throw error
        } catch {
            throw .invalidRequest("the request body is not valid JSON")
        }

        guard let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw .invalidRequest("'messages' must be a non-empty array of message objects", param: "messages")
        }

        var instructions: [String] = []
        var turns: [(role: String, text: String)] = []
        var image: ImageInput?
        var lastUserTurn: Int?

        for (index, message) in messages.enumerated() {
            guard let role = message["role"] as? String else {
                throw .invalidRequest("messages[\(index)] has no role", param: "messages")
            }
            let (text, images) = try content(of: message["content"], at: index)
            switch role {
            case "system", "developer":
                if !text.isEmpty { instructions.append(text) }
            case "user":
                turns.append((role, text))
                if let last = images.last { image = last }
                lastUserTurn = turns.count - 1
            case "assistant", "tool":
                if !text.isEmpty { turns.append((role, text)) }
            default:
                throw .invalidRequest("messages[\(index)] has unsupported role '\(role)'", param: "messages")
            }
        }

        guard let lastUserTurn else {
            throw .invalidRequest("'messages' must contain at least one user message", param: "messages")
        }
        var latest = turns[lastUserTurn].text
        if latest.isEmpty {
            guard image != nil else {
                throw .invalidRequest("the last user message has no text or image", param: "messages")
            }
            latest = ChatRequest.defaultImagePrompt
        }

        var request = ChatRequest(
            instructions: instructions.isEmpty ? nil : instructions.joined(separator: "\n\n"),
            prompt: prompt(latest: latest, history: turns[..<lastUserTurn]),
            image: image
        )

        if let n = object["n"], (n as? Int) != 1 {
            throw .invalidRequest("only n=1 is supported", param: "n")
        }
        if let stream = object["stream"] {
            guard let flag = stream as? Bool else { throw .invalidRequest("'stream' must be a boolean", param: "stream") }
            request.stream = flag
        }
        if let options = object["stream_options"] as? [String: Any] {
            request.includeUsageInStream = options["include_usage"] as? Bool ?? false
        }
        if let raw = object["temperature"], !(raw is NSNull) {
            guard let temperature = number(raw), (0...2).contains(temperature) else {
                throw .invalidRequest("'temperature' must be a number between 0 and 2", param: "temperature")
            }
            request.temperature = temperature
        }
        for key in ["max_completion_tokens", "max_tokens"] {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            guard let value = number(raw), value >= 1, value <= 1_000_000, value == value.rounded() else {
                throw .invalidRequest("'\(key)' must be a positive integer", param: key)
            }
            request.maxTokens = Int(value)
            break
        }
        return request
    }

    /// Text and images of one message's content: a string, an array of parts, or null.
    private static func content(of raw: Any?, at index: Int) throws(APIError) -> (String, [ImageInput]) {
        switch raw {
        case nil, is NSNull:
            return ("", [])
        case let text as String:
            return (text, [])
        case let parts as [[String: Any]]:
            var texts: [String] = []
            var images: [ImageInput] = []
            for part in parts {
                switch part["type"] as? String {
                case "text":
                    texts.append(part["text"] as? String ?? "")
                case "image_url":
                    let url = (part["image_url"] as? [String: Any])?["url"] as? String ?? part["image_url"] as? String
                    guard let url else {
                        throw .invalidRequest("messages[\(index)] has an image_url part without a url", param: "messages")
                    }
                    images.append(try image(from: url))
                case let other:
                    throw .invalidRequest("messages[\(index)] has an unsupported content part type '\(other ?? "none")'", param: "messages")
                }
            }
            return (texts.joined(separator: "\n"), images)
        default:
            throw .invalidRequest("messages[\(index)].content must be a string or an array of parts", param: "messages")
        }
    }

    static func image(from url: String) throws(APIError) -> ImageInput {
        if url.hasPrefix("data:") {
            guard let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") else {
                throw .invalidRequest("image data URIs must be base64-encoded (data:image/...;base64,...)", code: "invalid_image")
            }
            guard let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters),
                  !data.isEmpty
            else {
                throw .invalidRequest("the image data URI is not valid base64", code: "invalid_image")
            }
            return .data(data)
        }
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            throw .invalidRequest("remote image URLs are not supported; send the image as a data: URI", code: "unsupported_image_url")
        }
        if url.hasPrefix("file://") {
            guard let path = URL(string: url)?.path, !path.isEmpty else {
                throw .invalidRequest("invalid file URL", code: "invalid_image")
            }
            return .file(path)
        }
        if url.hasPrefix("/") { return .file(url) }
        throw .invalidRequest("unsupported image URL; send the image as a data: URI", code: "unsupported_image_url")
    }

    /// Earlier turns are replayed as a short transcript ahead of the latest message,
    /// since each request starts a fresh on-device session.
    static func prompt(latest: String, history: ArraySlice<(role: String, text: String)>) -> String {
        let earlier = history.filter { !$0.text.isEmpty }
        guard !earlier.isEmpty else { return latest }
        let names = ["user": "User", "assistant": "Assistant", "tool": "Tool result"]
        let transcript = earlier.map { "\(names[$0.role] ?? $0.role): \($0.text)" }.joined(separator: "\n")
        return "Conversation so far:\n\(transcript)\n\nLatest message from the user:\n\(latest)"
    }

    private static func number(_ raw: Any) -> Double? {
        // JSONSerialization turns true/false into NSNumber too; don't accept those as numbers.
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

// MARK: - Response encoding

public enum OpenAIEncoding {
    public struct Usage: Encodable, Equatable, Sendable {
        public let promptTokens: Int
        public let completionTokens: Int
        public var totalTokens: Int { promptTokens + completionTokens }

        public init(promptTokens: Int, completionTokens: Int) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
        }

        enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens" }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(promptTokens, forKey: .promptTokens)
            try c.encode(completionTokens, forKey: .completionTokens)
            try c.encode(totalTokens, forKey: .totalTokens)
        }
    }

    struct Message: Encodable { let role: String; let content: String }

    struct Choice: Encodable {
        let index: Int
        let message: Message
        let finishReason: String
        enum CodingKeys: String, CodingKey { case index, message, finishReason = "finish_reason" }
    }

    struct Completion: Encodable {
        let id: String
        let object = "chat.completion"
        let created: Int
        let model = modelID
        let choices: [Choice]
        let usage: Usage
    }

    struct Delta: Encodable { let role: String?; let content: String? }

    struct ChunkChoice: Encodable {
        let index: Int
        let delta: Delta
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case index, delta, finishReason = "finish_reason" }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(index, forKey: .index)
            try c.encode(delta, forKey: .delta)
            try c.encode(finishReason, forKey: .finishReason)   // explicit null while streaming, as OpenAI sends it
        }
    }

    struct Chunk: Encodable {
        let id: String
        let object = "chat.completion.chunk"
        let created: Int
        let model = modelID
        let choices: [ChunkChoice]
        let usage: Usage?
    }

    struct ErrorBody: Encodable {
        struct Detail: Encodable {
            let message: String
            let type: String
            let code: String?
            let param: String?

            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(message, forKey: .message)
                try c.encode(type, forKey: .type)
                try c.encode(code, forKey: .code)
                try c.encode(param, forKey: .param)
            }
            enum CodingKeys: String, CodingKey { case message, type, code, param }
        }
        let error: Detail
    }

    struct ModelEntry: Encodable {
        let id = modelID
        let object = "model"
        let created = 0
        let ownedBy = "apple"
        enum CodingKeys: String, CodingKey { case id, object, created, ownedBy = "owned_by" }
    }

    struct ModelList: Encodable { let object = "list"; let data = [ModelEntry()] }

    static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding these plain value types cannot fail.
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    public static func completion(id: String, created: Int, content: String, usage: Usage) -> Data {
        encode(Completion(id: id, created: created,
                          choices: [Choice(index: 0, message: Message(role: "assistant", content: content), finishReason: "stop")],
                          usage: usage))
    }

    public static func chunk(id: String, created: Int, role: String? = nil, content: String? = nil, finishReason: String? = nil) -> Data {
        encode(Chunk(id: id, created: created,
                     choices: [ChunkChoice(index: 0, delta: Delta(role: role, content: content), finishReason: finishReason)],
                     usage: nil))
    }

    public static func usageChunk(id: String, created: Int, usage: Usage) -> Data {
        encode(Chunk(id: id, created: created, choices: [], usage: usage))
    }

    public static func error(_ error: APIError) -> Data {
        encode(ErrorBody(error: .init(message: error.message, type: error.type, code: error.code, param: error.param)))
    }

    public static func models() -> Data { encode(ModelList()) }

    public static func event(_ json: Data) -> Data {
        var out = Data("data: ".utf8)
        out.append(json)
        out.append(Data("\n\n".utf8))
        return out
    }

    public static let done = Data("data: [DONE]\n\n".utf8)
}
