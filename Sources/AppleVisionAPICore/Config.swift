import Foundation

/// Server settings, from command-line flags and the environment.
public struct ServerConfig: Equatable, Sendable {
    public var host = "127.0.0.1"
    public var port: UInt16 = 8099
    public var apiKey: String?
    public var allowLocalFiles = false
    public var maxBodyBytes = 25 * 1024 * 1024
    /// Time a client gets to send a complete request before the connection is dropped.
    public var requestTimeout: TimeInterval = 60
    /// Connections handled at once; extra ones get 503.
    public var maxConnections = 32

    public init() {}

    public var isLoopbackOnly: Bool {
        ["127.0.0.1", "::1", "localhost"].contains(host)
    }

    public static let usage = """
    usage: apple_vision_api [options] [port]

      --host <address>       address to listen on (default 127.0.0.1, this Mac only;
                             use 0.0.0.0 to accept connections from your network)
      --port <number>        port to listen on (default 8099; a bare number also works)
      --api-key <key>        require "Authorization: Bearer <key>" on /v1 endpoints
                             (or set APPLE_VISION_API_KEY)
      --allow-local-files    accept image_url file paths, from clients on this Mac only
      --max-body-mb <n>      largest accepted request body, in MB (default 25)
      -h, --help             show this help
    """

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case helpRequested
        case invalid(String)

        public var description: String {
            switch self {
            case .helpRequested: return ServerConfig.usage
            case .invalid(let message): return "\(message)\n\n\(ServerConfig.usage)"
            }
        }
    }

    public static func parse(_ arguments: [String], environment: [String: String] = [:]) throws(ParseError) -> ServerConfig {
        var config = ServerConfig()
        var args = arguments[...]

        func value(for flag: String) throws(ParseError) -> String {
            guard let next = args.popFirst(), !next.hasPrefix("--") else {
                throw .invalid("\(flag) needs a value")
            }
            return next
        }

        func port(from text: String) throws(ParseError) -> UInt16 {
            guard let port = UInt16(text), port > 0 else { throw .invalid("invalid port: \(text)") }
            return port
        }

        while let arg = args.popFirst() {
            switch arg {
            case "-h", "--help":
                throw .helpRequested
            case "--host":
                config.host = try value(for: arg)
            case "--port":
                config.port = try port(from: try value(for: arg))
            case "--api-key":
                config.apiKey = try value(for: arg)
            case "--allow-local-files":
                config.allowLocalFiles = true
            case "--max-body-mb":
                let text = try value(for: arg)
                guard let mb = Int(text), (1...1024).contains(mb) else {
                    throw .invalid("invalid --max-body-mb: \(text) (1-1024)")
                }
                config.maxBodyBytes = mb * 1024 * 1024
            default:
                // A bare number is the port, as in earlier versions (`apple_vision_api 8099`).
                guard arg.allSatisfy(\.isNumber) else { throw .invalid("unknown option: \(arg)") }
                config.port = try port(from: arg)
            }
        }

        if config.apiKey == nil, let key = environment["APPLE_VISION_API_KEY"], !key.isEmpty {
            config.apiKey = key
        }
        if config.apiKey?.isEmpty == true {
            throw .invalid("--api-key must not be empty")
        }
        return config
    }
}
