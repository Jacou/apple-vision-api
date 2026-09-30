import AppleVisionAPICore
import Foundation

@main
enum App {
    static func main() async {
        let config: ServerConfig
        do {
            config = try ServerConfig.parse(Array(CommandLine.arguments.dropFirst()),
                                            environment: ProcessInfo.processInfo.environment)
        } catch .helpRequested {
            print(ServerConfig.usage)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(2)
        }

        let backend = AppleFoundationBackend()
        switch backend.availability() {
        case .available: log("on-device model available")
        case .unavailable(let reason): log("warning: on-device model unavailable: \(reason); requests will get 503 until this is fixed")
        }
        if !config.isLoopbackOnly && config.apiKey == nil {
            log("warning: listening on \(config.host) without an API key; anyone who can reach this port can use the model (set --api-key)")
        }
        if config.allowLocalFiles {
            log("local image file paths enabled for clients on this Mac only")
        }

        let server = Server(config: config, router: Router(config: config, backend: backend))
        do {
            try server.start()
        } catch {
            log("failed to start: \(error)")
            exit(1)
        }
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }
}
