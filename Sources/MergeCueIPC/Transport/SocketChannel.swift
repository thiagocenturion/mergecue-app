import Darwin
import Dispatch
import Foundation

/// A non-blocking, newline-framed stream socket driven by `DispatchSource`s.
///
/// Every piece of mutable state is confined to `queue` (hence `@unchecked Sendable`); methods whose name ends in
/// `OnQueue` must be called on it, the others hop onto it. Callbacks are invoked on `queue`. No call ever blocks:
/// reads and writes run when the kernel reports readiness, so neither the Swift concurrency pool nor the queue is
/// held while a peer is slow.
///
/// Lifecycle: `idle` → `startOnQueue` → `open` → `closeNow` (explicit, EOF, I/O error, or after flushing a
/// frame queued with `closeAfterFlush`) → `closed`. The file descriptor is closed once both sources finished
/// cancelling. After a write fails with `EPIPE`/`ECONNRESET` the channel keeps reading until EOF so that a
/// reply the peer sent just before closing (e.g. an authorization error) is still delivered.
final class SocketChannel: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case frame(Data)
        /// The peer sent a frame larger than the limit; reading stopped for good.
        case frameTooLarge
    }

    enum CloseReason: Sendable, Equatable {
        case local
        case peerClosed
        case readFailed(Int32)
        case writeFailed(Int32)
    }

    private enum State {
        case idle, open, closed
    }

    let queue: DispatchQueue
    private let fd: Int32
    private var decoder: FrameDecoder
    private var state = State.idle

    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pendingCancellations = 0
    /// The read source is currently suspended.
    private var readSuspended = false
    /// Flow control requested by the owner.
    private var readPaused = false
    /// Reading ended for good (frame overflow).
    private var readStopped = false
    /// The write source is resumed (it starts inactive).
    private var writeSourceActive = false

    private var output: [UInt8] = []
    private var outputOffset = 0
    private var closeWhenFlushed = false
    private var writeClosed = false
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    private var onEvent: ((Event) -> Void)?
    private var onClose: ((CloseReason) -> Void)?

    /// Takes ownership of `fd` (already non-blocking, close-on-exec and `SO_NOSIGPIPE`).
    init(fd: Int32, queue: DispatchQueue, maxFrameBytes: Int) {
        self.fd = fd
        self.queue = queue
        self.decoder = FrameDecoder(maxFrameBytes: maxFrameBytes)
    }

    // MARK: Lifecycle

    func startOnQueue(onEvent: @escaping (Event) -> Void, onClose: @escaping (CloseReason) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .idle else { return }
        state = .open
        self.onEvent = onEvent
        self.onClose = onClose

        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        pendingCancellations = 2
        read.setEventHandler { self.handleReadable() }
        read.setCancelHandler { self.sourceDidCancel() }
        write.setEventHandler { self.flush() }
        write.setCancelHandler { self.sourceDidCancel() }
        readSource = read
        writeSource = write
        read.resume()
    }

    /// Closes the channel (pending output is dropped). Safe to call from any thread, any number of times.
    func close() {
        queue.async { self.closeNow(.local) }
    }

    func closeNow(_ reason: CloseReason) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch state {
        case .closed:
            return
        case .idle:
            state = .closed
            Darwin.close(fd)
        case .open:
            state = .closed
            if let readSource {
                if readSuspended { readSource.resume() }
                readSource.cancel()
            }
            if let writeSource {
                if !writeSourceActive { writeSource.resume() }
                writeSource.cancel()
            }
        }
        readSource = nil
        writeSource = nil
        readSuspended = false
        writeSourceActive = false
        output = []
        outputOffset = 0
        let handler = onClose
        onClose = nil
        onEvent = nil
        handler?(reason)
    }

    private func sourceDidCancel() {
        pendingCancellations -= 1
        if pendingCancellations == 0 {
            Darwin.close(fd)
        }
    }

    // MARK: Writing

    /// Queues `frame` + `\n`. With `closeAfterFlush` the channel closes once everything queued was written.
    func send(_ frame: Data, closeAfterFlush: Bool = false) {
        queue.async { self.sendOnQueue(frame, closeAfterFlush: closeAfterFlush) }
    }

    func sendOnQueue(_ frame: Data, closeAfterFlush: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .open else { return }
        if writeClosed {
            if closeAfterFlush { closeNow(.local) }
            return
        }
        output.append(contentsOf: frame)
        output.append(UInt8(ascii: "\n"))
        if closeAfterFlush { closeWhenFlushed = true }
        flush()
    }

    private func flush() {
        guard state == .open, !writeClosed else { return }
        while outputOffset < output.count {
            let written = output.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + outputOffset, raw.count - outputOffset)
            }
            if written > 0 {
                outputOffset += written
                continue
            }
            let code = written < 0 ? errno : EAGAIN
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK {
                setWriteSourceActive(true)
                return
            }
            writeDidFail(code)
            return
        }
        output = []
        outputOffset = 0
        setWriteSourceActive(false)
        if closeWhenFlushed {
            closeNow(.local)
        }
    }

    private func writeDidFail(_ code: Int32) {
        writeClosed = true
        output = []
        outputOffset = 0
        setWriteSourceActive(false)
        // The peer is gone for writing; keep reading (a reply may still be buffered) unless nothing more can come.
        if closeWhenFlushed || readStopped || (code != EPIPE && code != ECONNRESET) {
            closeNow(.writeFailed(code))
        }
    }

    private func setWriteSourceActive(_ active: Bool) {
        guard let writeSource, active != writeSourceActive else { return }
        if active {
            writeSource.resume()
        } else {
            writeSource.suspend()
        }
        writeSourceActive = active
    }

    // MARK: Reading

    /// Pauses/resumes reading (flow control); frames already decoded are still delivered.
    func setReadingPaused(_ paused: Bool) {
        queue.async { self.setReadingPausedOnQueue(paused) }
    }

    func setReadingPausedOnQueue(_ paused: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        readPaused = paused
        updateReadSuspension()
    }

    private func updateReadSuspension() {
        guard state == .open, let readSource else { return }
        let shouldSuspend = readPaused || readStopped
        if shouldSuspend, !readSuspended {
            readSource.suspend()
            readSuspended = true
        } else if !shouldSuspend, readSuspended {
            readSource.resume()
            readSuspended = false
        }
    }

    private func handleReadable() {
        // Bounded batch per callback so one chatty peer cannot monopolize the queue; the source fires again.
        for _ in 0..<16 {
            guard state == .open, !readSuspended else { return }
            let count = readBuffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(fd, base, raw.count)
            }
            if count > 0 {
                let decoded = decoder.append(readBuffer[0..<count])
                for frame in decoded.frames {
                    guard state == .open else { return }
                    onEvent?(.frame(frame))
                }
                if decoded.overflowed {
                    readStopped = true
                    updateReadSuspension()
                    guard state == .open else { return }
                    onEvent?(.frameTooLarge)
                    if writeClosed { closeNow(.peerClosed) }
                    return
                }
            } else if count == 0 {
                closeNow(.peerClosed)
                return
            } else {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { return }
                closeNow(.readFailed(code))
                return
            }
        }
    }
}
