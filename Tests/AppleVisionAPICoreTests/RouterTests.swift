import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AppleVisionAPICore

// MARK: - Test doubles

struct FakeBackend: ModelBackend {
    var available: ModelAvailability = .available
    var reply = "fake reply"
    var chunks = ["Hel", "lo"]
    var error: APIError?
    let seen = Recorder()

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [(ChatRequest, Data?)] = []
        func add(_ r: ChatRequest, _ d: Data?) { lock.lock(); _requests.append((r, d)); lock.unlock() }
        var requests: [(ChatRequest, Data?)] { lock.lock(); defer { lock.unlock() }; return _requests }
    }

    func availability() -> ModelAvailability { available }

    func respond(to request: ChatRequest, imageData: Data?) async throws -> ModelOutput {
        seen.add(request, imageData)
        if let error { throw error }
        return ModelOutput(text: reply, usage: .init(promptTokens: 11, completionTokens: 3))
    }

    func stream(_ request: ChatRequest, imageData: Data?) -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        seen.add(request, imageData)
        return AsyncThrowingStream { continuation in
            if let error { continuation.finish(throwing: error); return }
            for chunk in chunks { continuation.yield(.delta(chunk)) }
            continuation.yield(.usage(.init(promptTokens: 11, completionTokens: 2)))
            continuation.finish()
        }
    }
}

final class MemoryWriter: ResponseWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func write(_ chunk: Data) async throws { lock.withLock { data.append(chunk) } }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    var statusLine: String { String(text.prefix { $0 != "\r" }) }
    var body: Data {
        let t = text
        guard let range = t.range(of: "\r\n\r\n") else { return Data() }
        return Data(t[range.upperBound...].utf8)
    }
    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
}

func pngData(width: Int = 4, height: Int = 4) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

// MARK: - Tests

struct RouterTests {
    func run(_ router: Router, _ method: String, _ path: String, body: String = "", headers: [String: String] = [:],
             loopback: Bool = false) async -> (Int, MemoryWriter) {
        let writer = MemoryWriter()
        let request = HTTPRequest(method: method, target: path, headers: headers, body: Data(body.utf8))
        let status = await router.handle(request, peerIsLoopback: loopback, writer: writer)
        return (status, writer)
    }

    func router(_ backend: FakeBackend = FakeBackend(), apiKey: String? = nil, allowLocalFiles: Bool = false) -> Router {
        var config = ServerConfig()
        config.apiKey = apiKey
        config.allowLocalFiles = allowLocalFiles
        return Router(config: config, backend: backend)
    }

    let chat = #"{"messages":[{"role":"user","content":"hi"}]}"#

    @Test func healthReflectsModelAvailability() async {
        let (ok, _) = await run(router(), "GET", "/health")
        #expect(ok == 200)
        let (down, writer) = await run(router(FakeBackend(available: .unavailable(reason: "Apple Intelligence is off"))), "GET", "/health")
        #expect(down == 503)
        #expect(writer.json?["reason"] as? String == "Apple Intelligence is off")
    }

    @Test func unknownPathsAndWrongMethods() async {
        #expect(await run(router(), "GET", "/nope").0 == 404)
        #expect(await run(router(), "GET", "/v1/chat/completions").0 == 405)
        #expect(await run(router(), "POST", "/health").0 == 405)
        #expect(await run(router(), "DELETE", "/v1/models").0 == 405)
    }

    @Test func queryStringsDoNotBreakRouting() async {
        #expect(await run(router(), "GET", "/v1/models?limit=1").0 == 200)
    }

    @Test func apiKeyIsRequiredWhenConfigured() async {
        let r = router(apiKey: "s3cret")
        #expect(await run(r, "GET", "/v1/models").0 == 401)
        #expect(await run(r, "GET", "/v1/models", headers: ["authorization": "Bearer wrong"]).0 == 401)
        #expect(await run(r, "POST", "/v1/chat/completions", body: chat).0 == 401)
        #expect(await run(r, "GET", "/v1/models", headers: ["authorization": "Bearer s3cret"]).0 == 200)
        #expect(await run(r, "GET", "/v1/models", headers: ["authorization": "bearer s3cret"]).0 == 200)
        #expect(await run(r, "GET", "/health").0 == 200)   // health stays open for monitoring
    }

    @Test func completionHasOpenAIShapeAndRealUsage() async throws {
        let (status, writer) = await run(router(), "POST", "/v1/chat/completions", body: chat)
        #expect(status == 200)
        let json = try #require(writer.json)
        #expect(json["object"] as? String == "chat.completion")
        let choice = try #require((json["choices"] as? [[String: Any]])?.first)
        #expect((choice["message"] as? [String: Any])?["content"] as? String == "fake reply")
        #expect(choice["finish_reason"] as? String == "stop")
        let usage = try #require(json["usage"] as? [String: Int])
        #expect(usage == ["prompt_tokens": 11, "completion_tokens": 3, "total_tokens": 14])
    }

    // Regression: replies with tabs, carriage returns or control characters produced invalid JSON.
    @Test func awkwardModelOutputStillProducesValidJSON() async throws {
        let nasty = "tab\there\r\nquote\" backslash\\ bell\u{07} null\u{00} emoji 🍎 </script>"
        let (_, writer) = await run(router(FakeBackend(reply: nasty)), "POST", "/v1/chat/completions", body: chat)
        let json = try #require(writer.json, "response body is not valid JSON")
        let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        #expect(content == nasty)
    }

    @Test func invalidRequestsGetOpenAIStyleErrors() async throws {
        let (status, writer) = await run(router(), "POST", "/v1/chat/completions", body: "{broken")
        #expect(status == 400)
        let error = try #require(writer.json?["error"] as? [String: Any])
        #expect(error["type"] as? String == "invalid_request_error")
        #expect(error["message"] as? String != nil)
    }

    @Test func modelUnavailableGives503() async {
        let backend = FakeBackend(available: .unavailable(reason: "off"))
        #expect(await run(router(backend), "POST", "/v1/chat/completions", body: chat).0 == 503)
    }

    @Test func backendErrorsKeepTheirStatus() async {
        let backend = FakeBackend(error: APIError(status: 429, message: "busy", type: "rate_limit_error"))
        #expect(await run(router(backend), "POST", "/v1/chat/completions", body: chat).0 == 429)
    }

    @Test func dataURIImagesAreDecodedAndPassedOn() async {
        let backend = FakeBackend()
        let png = pngData()
        let body = #"{"messages":[{"role":"user","content":[{"type":"text","text":"what?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(png.base64EncodedString())"}}]}]}"#
        #expect(await run(router(backend), "POST", "/v1/chat/completions", body: body).0 == 200)
        #expect(backend.seen.requests.first?.1 == png)
    }

    @Test func undecodableImagesAreRejected() async {
        let junk = Data("not an image".utf8).base64EncodedString()
        let body = #"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(junk)"}}]}]}"#
        #expect(await run(router(), "POST", "/v1/chat/completions", body: body).0 == 400)
    }

    // Regression: any network client could make the server read image files from its disk.
    @Test func localFilePathsNeedTheFlagAndALocalClient() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("avapi-test-\(UUID().uuidString).png")
        try pngData().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let body = #"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"\#(file.path)"}}]}]}"#

        #expect(await run(router(), "POST", "/v1/chat/completions", body: body, loopback: true).0 == 403)
        #expect(await run(router(allowLocalFiles: true), "POST", "/v1/chat/completions", body: body, loopback: false).0 == 403)
        #expect(await run(router(allowLocalFiles: true), "POST", "/v1/chat/completions", body: body, loopback: true).0 == 200)
    }

    @Test func streamingSendsServerSentEvents() async throws {
        let body = #"{"messages":[{"role":"user","content":"hi"}],"stream":true,"stream_options":{"include_usage":true}}"#
        let (status, writer) = await run(router(), "POST", "/v1/chat/completions", body: body)
        #expect(status == 200)
        #expect(writer.text.contains("Content-Type: text/event-stream"))

        let events = writer.text.components(separatedBy: "\n\n").filter { $0.hasPrefix("data: ") }.map { String($0.dropFirst(6)) }
        #expect(events.last == "[DONE]")
        let chunks = try events.dropLast().map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(chunks.allSatisfy { $0["object"] as? String == "chat.completion.chunk" })

        let deltas = chunks.compactMap { (($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String }
        #expect(deltas.joined() == "Hello")
        let finish = chunks.compactMap { ($0["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String }
        #expect(finish == ["stop"])
        #expect((chunks.last?["usage"] as? [String: Int])?["total_tokens"] == 13)
    }

    @Test func streamingErrorsBeforeTheFirstTokenGetAProperStatus() async {
        let backend = FakeBackend(error: APIError.invalidRequest("blocked", code: "content_policy_violation"))
        let (status, writer) = await run(router(backend), "POST", "/v1/chat/completions",
                                         body: #"{"messages":[{"role":"user","content":"hi"}],"stream":true}"#)
        #expect(status == 400)
        #expect(!writer.text.contains("text/event-stream"))
    }
}
