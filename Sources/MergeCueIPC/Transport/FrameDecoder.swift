import Foundation

/// Splits a byte stream into newline-delimited frames and enforces the maximum frame size.
///
/// - A frame is every byte up to (not including) `\n`; a trailing `\r` is dropped and empty frames are skipped.
/// - A frame longer than `maxFrameBytes` — or a partial frame that already exceeds it — sets `overflowed`. The
///   condition is sticky: once a stream overflowed, it is out of sync and must be closed.
/// - Scanning resumes where the previous call stopped, so a large frame arriving in small chunks costs O(n).
struct FrameDecoder: Sendable {
    struct Output: Sendable, Equatable {
        /// Complete frames, in order (frames preceding an overflow are still delivered).
        var frames: [Data]
        /// The frame size limit was exceeded; no further frames will be produced.
        var overflowed: Bool
    }

    let maxFrameBytes: Int
    private var buffer: [UInt8] = []
    /// Prefix of `buffer` already scanned without finding a newline.
    private var scannedCount = 0
    private(set) var overflowed = false

    init(maxFrameBytes: Int = IPCProtocol.maxFrameBytes) {
        self.maxFrameBytes = max(1, maxFrameBytes)
    }

    /// Bytes buffered for the current, incomplete frame.
    var pendingByteCount: Int { buffer.count }

    mutating func append(_ bytes: some Collection<UInt8>) -> Output {
        guard !overflowed else { return Output(frames: [], overflowed: true) }
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        var frameStart = 0
        var searchFrom = scannedCount
        while searchFrom < buffer.count, let newline = buffer[searchFrom...].firstIndex(of: UInt8(ascii: "\n")) {
            if newline - frameStart > maxFrameBytes {
                return overflow(keeping: frames)
            }
            var frameEnd = newline
            if frameEnd > frameStart, buffer[frameEnd - 1] == UInt8(ascii: "\r") {
                frameEnd -= 1
            }
            if frameEnd > frameStart {
                frames.append(Data(buffer[frameStart..<frameEnd]))
            }
            frameStart = newline + 1
            searchFrom = frameStart
        }
        if buffer.count - frameStart > maxFrameBytes {
            return overflow(keeping: frames)
        }
        if frameStart > 0 {
            buffer.removeFirst(frameStart)
        }
        scannedCount = buffer.count
        return Output(frames: frames, overflowed: false)
    }

    private mutating func overflow(keeping frames: [Data]) -> Output {
        overflowed = true
        buffer = []
        scannedCount = 0
        return Output(frames: frames, overflowed: true)
    }
}
