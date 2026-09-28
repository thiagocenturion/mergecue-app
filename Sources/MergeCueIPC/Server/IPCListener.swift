import Darwin
import Dispatch
import Foundation
import MergeCueCore
import Synchronization

/// Accepts connections on the listening socket (dispatch read source on a private queue), applies the uid check
/// and connection limit, and owns the live connections. All mutable state is confined to `queue`.
final class IPCListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.mergecue.ipc.accept", qos: .userInitiated)
    private let connectionTarget = DispatchQueue(label: "dev.mergecue.ipc.connections", qos: .userInitiated, attributes: .concurrent)
    private let listeningFD: Int32
    private let processor: IPCRequestProcessor
    private let configuration: IPCServer.Configuration
    private let peerValidator: (any PeerValidator)?
    private let serverUID = getuid()
    private let log = MCLog.ipc

    private var source: DispatchSourceRead?
    private var acceptSuspended = false
    private var stopped = false
    private var connections: [UInt64: IPCServerConnection] = [:]
    private var nextConnectionID: UInt64 = 0

    /// Takes ownership of `listeningFD` (bound, listening, non-blocking).
    init(listeningFD: Int32, processor: IPCRequestProcessor, configuration: IPCServer.Configuration, peerValidator: (any PeerValidator)?) {
        self.listeningFD = listeningFD
        self.processor = processor
        self.configuration = configuration
        self.peerValidator = peerValidator
    }

    func start() {
        queue.async {
            guard !self.stopped, self.source == nil else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: self.listeningFD, queue: self.queue)
            let fd = self.listeningFD
            source.setEventHandler { self.acceptPending() }
            source.setCancelHandler { Darwin.close(fd) }
            self.source = source
            source.resume()
        }
    }

    /// Stops accepting, closes the listening descriptor and every live connection.
    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            if let source = self.source {
                if self.acceptSuspended { source.resume() }
                source.cancel()
            } else {
                Darwin.close(self.listeningFD)
            }
            self.source = nil
            let live = self.connections.values
            self.connections = [:]
            for connection in live {
                connection.close()
            }
        }
    }

    /// Number of open connections (diagnostics/tests).
    func connectionCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.connections.count) }
        }
    }

    // MARK: Accepting

    private func acceptPending() {
        for _ in 0..<64 {
            guard !stopped else { return }
            let clientFD = accept(listeningFD, nil, nil)
            if clientFD >= 0 {
                admit(clientFD)
                continue
            }
            let code = errno
            switch code {
            case EINTR, ECONNABORTED:
                continue
            case EAGAIN, EWOULDBLOCK:
                return
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                log.error("IPC: accept failed (\(POSIXSocket.describe(code))); pausing briefly")
                pauseAccepting(for: 0.25)
                return
            default:
                log.error("IPC: accept failed (\(POSIXSocket.describe(code)))")
                return
            }
        }
    }

    private func admit(_ clientFD: Int32) {
        guard POSIXSocket.configure(clientFD), POSIXSocket.setNonBlocking(clientFD) else {
            Darwin.close(clientFD)
            return
        }
        guard let peer = POSIXSocket.peerCredentials(clientFD) else {
            log.notice("IPC: rejected a connection whose peer credentials could not be read")
            Darwin.close(clientFD)
            return
        }
        guard peer.uid == serverUID else {
            log.notice("IPC: rejected a connection from uid \(peer.uid) (server uid \(serverUID))")
            Darwin.close(clientFD)
            return
        }
        guard connections.count < configuration.maxConnections else {
            log.notice("IPC: rejected a connection; \(configuration.maxConnections) connections already open")
            Darwin.close(clientFD)
            return
        }
        nextConnectionID += 1
        let id = nextConnectionID
        let connection = IPCServerConnection(
            id: id,
            fd: clientFD,
            peer: peer,
            processor: processor,
            configuration: configuration,
            peerValidator: peerValidator,
            targetQueue: connectionTarget,
            onClosed: { [weak self] closedID in
                guard let self else { return }
                self.queue.async { self.connections[closedID] = nil }
            }
        )
        connections[id] = connection
        connection.start()
    }

    private func pauseAccepting(for seconds: TimeInterval) {
        guard let source, !acceptSuspended else { return }
        source.suspend()
        acceptSuspended = true
        queue.asyncAfter(deadline: .now() + seconds) {
            guard !self.stopped, self.acceptSuspended, let source = self.source else { return }
            self.acceptSuspended = false
            source.resume()
        }
    }
}

/// One accepted client. Frames are processed strictly in order by a single task, so responses on a connection
/// come back in request order while different connections proceed independently. Reading pauses while too many
/// requests are queued (back-pressure) and the connection closes if no frame arrives within the handshake window.
final class IPCServerConnection: @unchecked Sendable {
    private enum Inbound: Sendable {
        case frame(Data)
        case frameTooLarge
    }

    let id: UInt64
    private let queue: DispatchQueue
    private let channel: SocketChannel
    private let peer: IPCPeerCredentials
    private let processor: IPCRequestProcessor
    private let configuration: IPCServer.Configuration
    private let peerValidator: (any PeerValidator)?
    private let onClosed: @Sendable (UInt64) -> Void
    private let inbound: AsyncStream<Inbound>
    private let inboundContinuation: AsyncStream<Inbound>.Continuation
    /// Set when the channel closed: requests still buffered in `inbound` are dropped instead of executed.
    private let isClosed = Mutex(false)
    private let log = MCLog.ipc

    // Confined to `queue`.
    private var queuedFrames = 0
    private var receivedAnyFrame = false
    /// Bumped on every frame and completed request; a pending idle check only fires if it is still current.
    private var activityGeneration: UInt64 = 0

    init(
        id: UInt64,
        fd: Int32,
        peer: IPCPeerCredentials,
        processor: IPCRequestProcessor,
        configuration: IPCServer.Configuration,
        peerValidator: (any PeerValidator)?,
        targetQueue: DispatchQueue,
        onClosed: @escaping @Sendable (UInt64) -> Void
    ) {
        self.id = id
        self.queue = DispatchQueue(label: "dev.mergecue.ipc.connection.\(id)", target: targetQueue)
        self.channel = SocketChannel(fd: fd, queue: queue, maxFrameBytes: configuration.maxFrameBytes)
        self.peer = peer
        self.processor = processor
        self.configuration = configuration
        self.peerValidator = peerValidator
        self.onClosed = onClosed
        (inbound, inboundContinuation) = AsyncStream<Inbound>.makeStream()
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func close() {
        channel.close()
    }

    private func startOnQueue() {
        channel.startOnQueue(
            onEvent: { event in self.receive(event) },
            onClose: { _ in
                self.isClosed.withLock { $0 = true }
                self.inboundContinuation.finish()
                self.onClosed(self.id)
            }
        )
        if let peerValidator {
            do {
                try peerValidator.validate(peer)
            } catch {
                log.notice("IPC: rejected \(peer): \(error.localizedDescription)")
                let rejection = IPCError.unauthorized("This process is not allowed to connect to MergeCue (code signature check failed).")
                channel.sendOnQueue(IPCRequestProcessor.rejectionFrame(rejection), closeAfterFlush: true)
                return
            }
        }
        let processor = processor
        let peer = peer
        let channel = channel
        let inbound = inbound
        Task {
            for await item in inbound {
                // The peer is gone (or the server stopped): do not execute requests nobody will read.
                if self.isClosed.withLock({ $0 }) { break }
                let reply = switch item {
                case .frame(let data): await processor.process(data, peer: peer)
                case .frameTooLarge: processor.frameTooLargeReply()
                }
                channel.send(reply.data, closeAfterFlush: reply.closeConnection)
                if reply.closeConnection { break }
                if case .frame = item { self.frameCompleted() }
            }
        }
        queue.asyncAfter(deadline: .now() + configuration.handshakeTimeout) { [weak self] in
            guard let self, !self.receivedAnyFrame else { return }
            self.log.notice("IPC: closing an idle connection that sent no request")
            self.channel.closeNow(.local)
        }
    }

    private func receive(_ event: SocketChannel.Event) {
        receivedAnyFrame = true
        activityGeneration &+= 1
        switch event {
        case .frame(let data):
            queuedFrames += 1
            inboundContinuation.yield(.frame(data))
            if queuedFrames >= configuration.maxQueuedRequestsPerConnection {
                channel.setReadingPausedOnQueue(true)
            }
        case .frameTooLarge:
            inboundContinuation.yield(.frameTooLarge)
        }
    }

    private func frameCompleted() {
        queue.async {
            self.queuedFrames = max(0, self.queuedFrames - 1)
            if self.queuedFrames < self.configuration.maxQueuedRequestsPerConnection {
                self.channel.setReadingPausedOnQueue(false)
            }
            self.scheduleIdleCheckOnQueue()
        }
    }

    /// Closes the connection if nothing happens within `idleTimeout` after the last completed request.
    private func scheduleIdleCheckOnQueue() {
        activityGeneration &+= 1
        let generation = activityGeneration
        queue.asyncAfter(deadline: .now() + configuration.idleTimeout) { [weak self] in
            guard let self, generation == self.activityGeneration, self.queuedFrames == 0 else { return }
            self.log.notice("IPC: closing a connection idle for \(self.configuration.idleTimeout) s")
            self.channel.closeNow(.local)
        }
    }
}
