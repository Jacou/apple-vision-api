import Testing
@testable import AppleVisionAPICore

struct ConfigTests {
    @Test func defaultsAreSafe() throws {
        let config = try ServerConfig.parse([])
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 8099)
        #expect(config.apiKey == nil)
        #expect(!config.allowLocalFiles)
        #expect(config.isLoopbackOnly)
    }

    @Test func bareNumberIsStillThePort() throws {
        #expect(try ServerConfig.parse(["9000"]).port == 9000)
    }

    @Test func flags() throws {
        let config = try ServerConfig.parse(["--host", "0.0.0.0", "--port", "8100", "--api-key", "s3cret", "--allow-local-files", "--max-body-mb", "10"])
        #expect(config.host == "0.0.0.0")
        #expect(config.port == 8100)
        #expect(config.apiKey == "s3cret")
        #expect(config.allowLocalFiles)
        #expect(config.maxBodyBytes == 10 * 1024 * 1024)
        #expect(!config.isLoopbackOnly)
    }

    @Test func apiKeyFromEnvironmentUnlessGivenAsFlag() throws {
        #expect(try ServerConfig.parse([], environment: ["APPLE_VISION_API_KEY": "env"]).apiKey == "env")
        #expect(try ServerConfig.parse(["--api-key", "flag"], environment: ["APPLE_VISION_API_KEY": "env"]).apiKey == "flag")
    }

    @Test(arguments: [["--port", "0"], ["--port", "70000"], ["--host"], ["--bogus"], ["--max-body-mb", "0"], ["--api-key", "--host"]])
    func rejectsBadArguments(_ args: [String]) {
        #expect(throws: ServerConfig.ParseError.self) { try ServerConfig.parse(args) }
    }

    @Test func helpFlag() {
        #expect(throws: ServerConfig.ParseError.helpRequested) { try ServerConfig.parse(["--help"]) }
    }

    @Test func constantTimeEquality() {
        #expect(constantTimeEquals("abc", "abc"))
        #expect(!constantTimeEquals("abc", "abd"))
        #expect(!constantTimeEquals("abc", "abcd"))
        #expect(!constantTimeEquals("", "a"))
    }
}
