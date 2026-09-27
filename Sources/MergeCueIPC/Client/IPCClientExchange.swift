import Darwin
import Dispatch
import Foundation
import MergeCueCore

/// One request/response round trip on its own connection, driven entirely on a private dispatch queue:
/// read token → connect → verify the server's uid → send → await one response frame → close. Bridged to async
/// code with a continuation, bounded by a timeout and cancellable. Never blocks the Swift concurrency pool.
///
/// When the server answers `unauthorized` and the token file changed since it was read (the app restarted
/// between the read and the request), the exchange reconnects once with the new token.
final class IPCClientExchange: @unchecked Sendable {
    struct Request: Sendable {
        var id: String
        var client: IPCClientInfo
        var method: IPCMethod
        var params: JSONValue
    }

    private let queue: DispatchQueue
    private let request: Request
    private let socketPath: String
    private let tokenPath: String
    private let timeout: TimeInterval
    private let maxFrameBytes: Int

    // Confined to `queue`.
    private var continuation: CheckedContinuation<Result<JSONValue, IPCError>, Never>?
    private var channel: SocketChannel?
    private var usedToken: String?
    private var retriedAfterUnauthorized = false
    private var finished = false
    private var cancelled = false

    private init(request: Request, socketPath: String, tokenPath: String, timeout: TimeInterval, maxFrameBytes: Int) {
        self.queue = DispatchQueue(label: "dev.mergecue.ipc.client", qos: .userInitiated)
        self.request = request
        self.socketPath = socketPath
        self.tokenPath = tokenPath
        self.timeout = timeout
        self.maxFrameBytes = maxFrameBytes
    }

    static func perform(
        _ request: Request,
        socketPath: String,
        tokenPath: String,
        timeout: TimeInterval,
        maxFrameBytes: Int = IPCProtocol.maxFrameBytes
    ) async -> Result<JSONValue, IPCError> {
        let exchange = IPCClientExchange(request: request, socketPath: socketPath, tokenPath: tokenPath, timeout: timeout, maxFrameBytes: maxFrameBytes)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                exchange.begin(continuation)
            }
        } onCancel: {
            exchange.cancel()
        }
    }

    // MARK: Flow

    private func begin(_ continuation: CheckedContinuation<Result<JSONValue, IPCError>, Never>) {
        queue.async {
            self.continuation = continuation
            if self.cancelled {
                self.finish(.failure(Self.cancelledError))
                return
            }
            let seconds = self.timeout
            self.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.finish(.failure(Self.timeoutError(seconds)))
            }
            self.attempt()
        }
    }

    private func cancel() {
        queue.async {
            self.cancelled = true
            if self.continuation != nil {
                self.finish(.failure(Self.cancelledError))
            }
        }
    }

    private func attempt() {
        guard !finished else { return }
        let token: String
        switch Self.readToken(at: tokenPath) {
        case .success(let value): token = value
        case .failure(let error):
            finish(.failure(error))
            return
        }
        usedToken = token

        let frame: Data
        do {
            let message = IPCRequest(id: request.id, token: token, client: request.client, method: request.method, params: request.params)
            frame = try IPCCoding.encodeFrame(message)
        } catch {
            finish(.failure(.invalidParams("The request could not be encoded: \(IPCCoding.bounded(String(describing: error)))")))
            return
        }
        guard frame.count <= maxFrameBytes else {
            finish(.failure(.invalidParams("The request exceeds the \(maxFrameBytes / (1024 * 1024)) MiB IPC frame limit.")))
            return
        }

        let address: sockaddr_un
        do {
            address = try POSIXSocket.address(for: socketPath)
        } catch {
            finish(.failure(.internalError("The MergeCue socket path is too long for a Unix socket: \(socketPath)")))
            return
        }
        let fd = POSIXSocket.makeStreamSocket()
        guard fd >= 0 else {
            finish(.failure(.internalError("Could not create a socket: \(POSIXSocket.describe(-fd)).", retryable: true)))
            return
        }
        // Unix-domain connect completes (or fails) immediately; it runs here, on the exchange's queue.
        let connectResult = POSIXSocket.connect(fd, to: address)
        guard connectResult == 0 else {
            Darwin.close(fd)
            finish(.failure(Self.connectError(connectResult)))
            return
        }
        // Mutual check before the token leaves the process: the listener must run as the current user.
        guard let server = POSIXSocket.peerCredentials(fd), server.uid == getuid() else {
            Darwin.close(fd)
            finish(.failure(.unauthorized("The MergeCue socket is not owned by the current user; refusing to send the token.")))
            return
        }
        guard POSIXSocket.setNonBlocking(fd) else {
            let code = errno
            Darwin.close(fd)
            finish(.failure(.internalError("Could not configure the socket: \(POSIXSocket.describe(code)).", retryable: true)))
            return
        }

        let channel = SocketChannel(fd: fd, queue: queue, maxFrameBytes: maxFrameBytes)
        self.channel = channel
        channel.startOnQueue(
            onEvent: { event in self.receive(event, on: channel) },
            onClose: { _ in self.channelDidClose(channel) }
        )
        channel.sendOnQueue(frame)
    }

    private func receive(_ event: SocketChannel.Event, on channel: SocketChannel) {
        guard channel === self.channel, !finished else { return }
        switch event {
        case .frameTooLarge:
            finish(.failure(.internalError("MergeCue sent a response larger than the \(maxFrameBytes / (1024 * 1024)) MiB IPC limit.")))
        case .frame(let data):
            guard let response = try? IPCCoding.decoder().decode(IPCResponse.self, from: data) else {
                finish(.failure(.internalError("MergeCue sent a malformed response.", reason: "malformed_response")))
                return
            }
            guard response.v == IPCProtocol.version else {
                finish(.failure(IPCError(
                    code: .protocolVersion,
                    message: "MergeCue answered with IPC protocol version \(response.v); this client speaks version \(IPCProtocol.version). Update mergecue-mcp and the app together.",
                    retryable: false
                )))
                return
            }
            // Connection-level rejections (peer validation) carry an empty id.
            guard response.id == request.id || (response.id.isEmpty && response.error != nil) else {
                finish(.failure(.internalError("MergeCue answered a different request (id mismatch).", reason: "id_mismatch")))
                return
            }
            let outcome = response.outcome
            if case .failure(let error) = outcome, error.code == .unauthorized, shouldRetryAfterUnauthorized() {
                retriedAfterUnauthorized = true
                self.channel = nil
                channel.closeNow(.local)
                attempt()
                return
            }
            finish(outcome)
        }
    }

    private func channelDidClose(_ channel: SocketChannel) {
        guard channel === self.channel, !finished else { return }
        finish(.failure(.appUnavailable(
            "MergeCue closed the connection before answering. Make sure the app is running, then retry.",
            reason: "connection_closed"
        )))
    }

    /// Retry once when the token on disk differs from the one that was rejected (the app restarted meanwhile).
    private func shouldRetryAfterUnauthorized() -> Bool {
        guard !retriedAfterUnauthorized, let usedToken, case .success(let current) = Self.readToken(at: tokenPath) else { return false }
        return current != usedToken
    }

    private func finish(_ result: Result<JSONValue, IPCError>) {
        guard !finished else { return }
        finished = true
        let channel = self.channel
        self.channel = nil
        channel?.closeNow(.local)
        continuation?.resume(returning: result)
        continuation = nil
    }

    // MARK: Errors

    static let cancelledError = IPCError.internalError("The request to MergeCue was cancelled.", retryable: true, reason: "cancelled")

    static func timeoutError(_ seconds: TimeInterval) -> IPCError {
        .appUnavailable(
            "MergeCue did not answer within \(Int(seconds.rounded(.up))) seconds. Make sure the app is running and responsive, then retry.",
            reason: "timeout"
        )
    }

    static func connectError(_ code: Int32) -> IPCError {
        switch code {
        case ENOENT, ECONNREFUSED, ENOTDIR:
            .appUnavailable(reason: "not_running")
        case EACCES, EPERM:
            .appUnavailable("MergeCue's IPC socket is not accessible (permission denied). Open MergeCue and retry.", reason: "permission_denied")
        case EAGAIN:
            .appUnavailable("MergeCue is busy and did not accept the connection. Retry shortly.", reason: "busy")
        default:
            .appUnavailable("Could not connect to MergeCue (\(POSIXSocket.describe(code))). Open MergeCue and retry.", reason: "connect_failed")
        }
    }

    /// Token file → token. Missing/unreadable/malformed tokens all mean the app is not (fully) running.
    static func readToken(at path: String) -> Result<String, IPCError> {
        switch IPCFileSecurity.readToken(at: path) {
        case .success(let token):
            guard IPCFileSecurity.isWellFormedToken(token) else {
                return .failure(.appUnavailable(reason: "token_invalid"))
            }
            return .success(token)
        case .failure(let error):
            if error.code == ENOENT || error.code == ENOTDIR {
                return .failure(.appUnavailable(reason: "token_missing"))
            }
            return .failure(.appUnavailable(
                "MergeCue's IPC token could not be read (\(POSIXSocket.describe(error.code))). Open MergeCue and retry.",
                reason: "token_unreadable"
            ))
        }
    }
}
