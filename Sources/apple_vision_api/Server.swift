import AppleVisionAPICore
import Foundation
import Network

/// Accepts connections and hands each complete request to the router.
final class Server: @unchecked Sendable {
    private let config: ServerConfig
    private let router: Router
    private var listener: NWListener?
    private let lock = NSLock()
    private var activeConnections = 0

    init(config: ServerConfig, router: Router) {
        self.config = config
        self.router = router
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: config.port) else { throw ServerError.invalidPort }

        let listener: NWListener
        if ["0.0.0.0", "::", "*"].contains(config.host) {
            listener = try NWListener(using: parameters, on: port)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(config.host), port: port)
            listener = try NWListener(using: parameters)
        }

        listener.stateUpdateHandler = { [config] state in
            switch state {
            case .ready: log("listening on \(config.host):\(config.port)")
            case .failed(let error): log("listener failed: \(error)"); exit(1)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func accept(_ nw: NWConnection) {
        lock.lock()
        let admitted = activeConnections < config.maxConnections
        if admitted { activeConnections += 1 }
        lock.unlock()

        let connection = Connection(nw, config: config, router: router) { [weak self] in
            guard let self, admitted else { return }
            self.lock.lock(); self.activeConnections -= 1; self.lock.unlock()
        }
        admitted ? connection.start() : connection.reject(HTTPError(503, "too many connections, try again shortly"))
    }

    enum ServerError: Error { case invalidPort }
}

/// One client connection: reads a single request, responds, closes.
/// Nothing outside holds on to it; it is released as soon as the connection ends,
/// together with the request buffer.
final class Connection: ResponseWriter, @unchecked Sendable {
    private let nw: NWConnection
    private let router: Router
    private let parser: HTTPRequestParser
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "apple-vision-api.connection")
    private let onClose: @Sendable () -> Void
    // Touched only on `queue`.
    private var buffer = Data()
    private var requestReceived = false
    private var closed = false

    init(_ nw: NWConnection, config: ServerConfig, router: Router, onClose: @escaping @Sendable () -> Void) {
        self.nw = nw
        self.router = router
        self.parser = HTTPRequestParser(maxBodyBytes: config.maxBodyBytes)
        self.timeout = config.requestTimeout
        self.onClose = onClose
    }

    func start() {
        nw.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: finish()
            default: break
            }
        }
        nw.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.requestReceived, !self.closed else { return }
            self.respondWithError(HTTPError(408, "timed out waiting for the request"))
        }
        receive()
    }

    func reject(_ error: HTTPError) {
        nw.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: respondWithError(error)
            case .failed, .cancelled: finish()
            default: break
            }
        }
        nw.start(queue: queue)
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if error != nil { close(); return }
            switch parser.parse(buffer) {
            case .complete(let request):
                requestReceived = true
                buffer = Data()
                dispatch(request)
            case .failed(let error):
                requestReceived = true
                buffer = Data()
                respondWithError(error)
            case .needMoreData:
                if isComplete { close() } else { receive() }
            }
        }
    }

    private func dispatch(_ request: HTTPRequest) {
        let loopback = Self.isLoopback(nw.endpoint)
        let started = Date()
        Task {
            let status = await router.handle(request, peerIsLoopback: loopback, writer: self)
            log("\(request.method) \(request.path) \(status) \(Int(Date().timeIntervalSince(started) * 1000))ms")
            queue.async { self.close() }
        }
    }

    private func respondWithError(_ error: HTTPError) {
        let body = OpenAIEncoding.error(APIError(status: error.status, message: error.message, type: "invalid_request_error"))
        nw.send(content: HTTPResponse.json(error.status, body).serialized(), completion: .contentProcessed { [self] _ in
            queue.async { self.close() }
        })
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            nw.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func close() {
        guard !closed else { return }
        nw.cancel()   // leads to .cancelled, which calls finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        buffer = Data()
        nw.stateUpdateHandler = nil   // breaks the connection <-> handler reference cycle
        onClose()
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || (address.asIPv4?.isLoopback ?? false)
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }
}

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
