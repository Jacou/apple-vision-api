import Foundation
import Testing
@testable import AppleVisionAPICore

struct HTTPParserTests {
    let parser = HTTPRequestParser(maxBodyBytes: 1024)

    func raw(_ text: String) -> Data { Data(text.utf8) }

    @Test func parsesGetWithoutBody() throws {
        let result = parser.parse(raw("GET /health HTTP/1.1\r\nHost: x\r\n\r\n"))
        guard case .complete(let request) = result else { Issue.record("expected complete, got \(result)"); return }
        #expect(request.method == "GET")
        #expect(request.path == "/health")
        #expect(request.body.isEmpty)
    }

    @Test func waitsForTheWholeBody() {
        let head = "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        #expect(parser.parse(raw(head + "12345")) == .needMoreData)
        guard case .complete(let request) = parser.parse(raw(head + "1234567890")) else { Issue.record("expected complete"); return }
        #expect(request.body == raw("1234567890"))
    }

    @Test func waitsForTheEndOfHeaders() {
        #expect(parser.parse(raw("GET /health HTTP/1.1\r\nHost: x\r\n")) == .needMoreData)
    }

    // Regression: a negative Content-Length used to crash the server.
    @Test(arguments: ["-5", "+5", "5.0", "abc", " ", "0x10", "99999999999999999999"])
    func rejectsInvalidContentLength(_ value: String) {
        let result = parser.parse(raw("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n{}"))
        #expect(result == .failed(HTTPError(400, "invalid Content-Length")))
    }

    @Test func rejectsBodiesOverTheLimit() {
        guard case .failed(let error) = parser.parse(raw("POST / HTTP/1.1\r\nContent-Length: 1025\r\n\r\n")) else {
            Issue.record("expected failure"); return
        }
        #expect(error.status == 413)
    }

    @Test func rejectsOversizedHeaders() {
        let small = HTTPRequestParser(maxHeaderBytes: 100, maxBodyBytes: 1024)
        let result = small.parse(raw("GET / HTTP/1.1\r\nX-Long: " + String(repeating: "a", count: 200)))
        guard case .failed(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.status == 431)
    }

    @Test func rejectsChunkedBodies() {
        guard case .failed(let error) = parser.parse(raw("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) else {
            Issue.record("expected failure"); return
        }
        #expect(error.status == 501)
    }

    @Test func rejectsConflictingContentLengths() {
        let result = parser.parse(raw("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}"))
        #expect(result == .failed(HTTPError(400, "conflicting Content-Length headers")))
    }

    @Test(arguments: ["GET\r\n\r\n", "GET /x\r\n\r\n", "get / HTTP/1.1\r\n\r\n", "GET x HTTP/1.1\r\n\r\n", "GET / FTP/1.0\r\n\r\n"])
    func rejectsMalformedRequestLines(_ text: String) {
        #expect(parser.parse(raw(text)) == .failed(HTTPError(400, "malformed request line")))
    }

    @Test func stripsTheQueryStringAndLowercasesHeaderNames() {
        guard case .complete(let request) = parser.parse(raw("GET /v1/models?x=1 HTTP/1.1\r\nAUTHORIZATION: Bearer k\r\n\r\n")) else {
            Issue.record("expected complete"); return
        }
        #expect(request.path == "/v1/models")
        #expect(request.target == "/v1/models?x=1")
        #expect(request.header("Authorization") == "Bearer k")
    }

    @Test func serializesResponsesWithLengthAndClose() {
        let text = String(decoding: HTTPResponse.json(404, raw("{}")).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }
}
