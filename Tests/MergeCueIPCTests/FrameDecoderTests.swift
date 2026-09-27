import Foundation
import Testing
@testable import MergeCueIPC

@Suite("Newline framing")
struct FrameDecoderTests {
    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    private func strings(_ output: FrameDecoder.Output) -> [String] {
        output.frames.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func splitsFramesAndKeepsPartialTail() {
        var decoder = FrameDecoder(maxFrameBytes: 100)
        var output = decoder.append(bytes("{\"a\":1}\n{\"b\":2}\n{\"c\""))
        #expect(strings(output) == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(!output.overflowed)
        #expect(decoder.pendingByteCount == 4)
        output = decoder.append(bytes(":3}\n"))
        #expect(strings(output) == [#"{"c":3}"#])
        #expect(decoder.pendingByteCount == 0)
    }

    @Test func handlesByteAtATimeCRLFAndBlankLines() {
        var decoder = FrameDecoder(maxFrameBytes: 100)
        var frames: [String] = []
        for byte in bytes("\n\r\none\r\n\ntwo\n") {
            frames += strings(decoder.append([byte]))
        }
        #expect(frames == ["one", "two"])
    }

    @Test func frameOfExactlyTheLimitIsAccepted() {
        var decoder = FrameDecoder(maxFrameBytes: 8)
        #expect(!decoder.append(bytes("12345678")).overflowed)
        #expect(strings(decoder.append(bytes("\n"))) == ["12345678"])
    }

    @Test func overflowWithoutNewlineIsDetectedEarly() {
        var decoder = FrameDecoder(maxFrameBytes: 8)
        #expect(!decoder.append(bytes("1234")).overflowed)
        let output = decoder.append(bytes("56789"))
        #expect(output.overflowed)
        #expect(output.frames.isEmpty)
        // Sticky: the stream is out of sync from now on.
        #expect(decoder.append(bytes("\nok\n")).overflowed)
        #expect(decoder.append(bytes("\nok\n")).frames.isEmpty)
    }

    @Test func framesBeforeAnOversizeFrameAreStillDelivered() {
        var decoder = FrameDecoder(maxFrameBytes: 8)
        let output = decoder.append(bytes("ok\n123456789\nlater\n"))
        #expect(strings(output) == ["ok"])
        #expect(output.overflowed)
    }

    @Test func largeFrameInSmallChunksIsLinear() {
        let limit = IPCProtocol.maxFrameBytes
        var decoder = FrameDecoder(maxFrameBytes: limit)
        let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 8192)
        var sent = 0
        while sent + chunk.count <= limit {
            #expect(!decoder.append(chunk).overflowed)
            sent += chunk.count
        }
        let output = decoder.append(bytes("\n"))
        #expect(output.frames.count == 1)
        #expect(output.frames.first?.count == sent)
    }
}
