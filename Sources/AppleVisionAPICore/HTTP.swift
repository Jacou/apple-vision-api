import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    /// The request target as sent, including any query string.
    public var target: String
    /// The target without its query string.
    public var path: String
    /// Header values keyed by lowercased name.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.target = target
        self.path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct HTTPError: Error, Equatable, Sendable {
    public let status: Int
    public let message: String

    public init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

public enum HTTPParseResult: Equatable, Sendable {
    case needMoreData
    case complete(HTTPRequest)
    case failed(HTTPError)
}

/// Parses one HTTP/1.1 request from the bytes received so far.
/// Strict on purpose: bad or oversized lengths are rejected instead of trusted.
public struct HTTPRequestParser: Sendable {
    public let maxHeaderBytes: Int
    public let maxBodyBytes: Int

    public init(maxHeaderBytes: Int = 64 * 1024, maxBodyBytes: Int) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    public func parse(_ buffer: Data) -> HTTPParseResult {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .failed(HTTPError(431, "request headers too large")) : .needMoreData
        }
        let headerBytes = buffer[buffer.startIndex..<separator.lowerBound]
        guard headerBytes.count <= maxHeaderBytes else {
            return .failed(HTTPError(431, "request headers too large"))
        }
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            return .failed(HTTPError(400, "request headers are not valid UTF-8"))
        }

        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              !requestLine[0].isEmpty, requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              requestLine[1].hasPrefix("/"),
              requestLine[2].hasPrefix("HTTP/1.")
        else {
            return .failed(HTTPError(400, "malformed request line"))
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                return .failed(HTTPError(400, "malformed header line"))
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
                return .failed(HTTPError(400, "malformed header name"))
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                if name == "content-length" {
                    guard existing == value else { return .failed(HTTPError(400, "conflicting Content-Length headers")) }
                    continue
                }
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        if headers["transfer-encoding"] != nil {
            return .failed(HTTPError(501, "chunked request bodies are not supported; send a Content-Length"))
        }

        var contentLength = 0
        if let raw = headers["content-length"] {
            // Digits only: rejects negative, signed, fractional and absurdly long values.
            guard !raw.isEmpty, raw.count <= 18, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber),
                  let length = Int(raw)
            else {
                return .failed(HTTPError(400, "invalid Content-Length"))
            }
            contentLength = length
        }
        guard contentLength <= maxBodyBytes else {
            return .failed(HTTPError(413, "request body too large (limit \(maxBodyBytes / (1024 * 1024)) MB)"))
        }

        let bodyStart = separator.upperBound
        guard buffer.endIndex - bodyStart >= contentLength else { return .needMoreData }
        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])

        return .complete(HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ body: Data, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")] + headers, body: body)
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    /// Response head for a Server-Sent Events stream; the body follows as events.
    public static let eventStreamHead = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8
    )

    public static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Content Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}
