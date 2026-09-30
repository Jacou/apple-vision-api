import Foundation
import Testing
@testable import AppleVisionAPICore

struct ChatRequestTests {
    func parse(_ json: String) throws(APIError) -> ChatRequest {
        try ChatRequestParser.parse(Data(json.utf8))
    }

    func parseError(_ json: String) -> APIError? {
        do { _ = try parse(json); return nil } catch { return error }
    }

    @Test func plainUserMessage() throws {
        let request = try parse(#"{"messages":[{"role":"user","content":"Hello"}]}"#)
        #expect(request.prompt == "Hello")
        #expect(request.instructions == nil)
        #expect(request.image == nil)
        #expect(!request.stream)
    }

    // Regression: system messages used to be ignored.
    @Test func systemAndDeveloperMessagesBecomeInstructions() throws {
        let request = try parse(#"""
        {"messages":[{"role":"system","content":"Answer in French."},{"role":"developer","content":"Be brief."},
                     {"role":"user","content":"What colour is the sky?"}]}
        """#)
        #expect(request.instructions == "Answer in French.\n\nBe brief.")
        #expect(request.prompt == "What colour is the sky?")
    }

    @Test func earlierTurnsAreReplayedBeforeTheLatestMessage() throws {
        let request = try parse(#"""
        {"messages":[{"role":"user","content":"My name is Ana."},{"role":"assistant","content":"Hi Ana!"},
                     {"role":"user","content":"What is my name?"}]}
        """#)
        #expect(request.prompt == "Conversation so far:\nUser: My name is Ana.\nAssistant: Hi Ana!\n\nLatest message from the user:\nWhat is my name?")
    }

    @Test func textPartsAndTheLatestImageAreUsed() throws {
        let first = Data([1, 2, 3]).base64EncodedString(), second = Data([4, 5, 6]).base64EncodedString()
        let request = try parse(#"""
        {"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(first)"}}]},
                     {"role":"user","content":[{"type":"text","text":"What is this?"},
                                               {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,\#(second)"}}]}]}
        """#)
        #expect(request.image == .data(Data([4, 5, 6])))
        #expect(request.prompt.hasSuffix("What is this?"))
    }

    @Test func imageOnlyMessageGetsADefaultPrompt() throws {
        let b64 = Data([1]).base64EncodedString()
        let request = try parse(#"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(b64)"}}]}]}"#)
        #expect(request.prompt == ChatRequest.defaultImagePrompt)
    }

    @Test func filePathsAndFileURLsAreRecognised() throws {
        #expect(try ChatRequestParser.image(from: "/Users/me/a.png") == .file("/Users/me/a.png"))
        #expect(try ChatRequestParser.image(from: "file:///Users/me/my%20photo.jpg") == .file("/Users/me/my photo.jpg"))
    }

    @Test(arguments: [
        ("https://example.com/cat.png", "unsupported_image_url"),
        ("ftp://x/y.png", "unsupported_image_url"),
        ("data:image/png,rawbytes", "invalid_image"),
        ("data:image/png;base64,***", "invalid_image"),
    ])
    func rejectsUnusableImageURLs(url: String, code: String) {
        let error = parseError(#"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"\#(url)"}}]}]}"#)
        #expect(error?.status == 400)
        #expect(error?.code == code)
    }

    @Test func samplingOptions() throws {
        let request = try parse(#"{"messages":[{"role":"user","content":"x"}],"temperature":0.3,"max_tokens":50,"stream":true,"stream_options":{"include_usage":true}}"#)
        #expect(request.temperature == 0.3)
        #expect(request.maxTokens == 50)
        #expect(request.stream)
        #expect(request.includeUsageInStream)
        #expect(try parse(#"{"messages":[{"role":"user","content":"x"}],"max_completion_tokens":7,"max_tokens":50}"#).maxTokens == 7)
    }

    @Test(arguments: [
        #"not json"#,
        #"[1,2]"#,
        #"{"messages":[]}"#,
        #"{"messages":"hi"}"#,
        #"{"messages":[{"content":"no role"}]}"#,
        #"{"messages":[{"role":"system","content":"only a system prompt"}]}"#,
        #"{"messages":[{"role":"user","content":""}]}"#,
        #"{"messages":[{"role":"wizard","content":"x"}]}"#,
        #"{"messages":[{"role":"user","content":[{"type":"input_audio"}]}]}"#,
        #"{"messages":[{"role":"user","content":"x"}],"temperature":5}"#,
        #"{"messages":[{"role":"user","content":"x"}],"temperature":true}"#,
        #"{"messages":[{"role":"user","content":"x"}],"max_tokens":0}"#,
        #"{"messages":[{"role":"user","content":"x"}],"max_tokens":2.5}"#,
        #"{"messages":[{"role":"user","content":"x"}],"n":2}"#,
        #"{"messages":[{"role":"user","content":"x"}],"stream":"yes"}"#,
    ])
    func rejectsInvalidRequestsWith400(_ json: String) {
        let error = parseError(json)
        #expect(error?.status == 400, "expected 400 for \(json)")
    }
}
