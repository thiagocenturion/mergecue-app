import Foundation
import MergeCueCore
import Testing

/// Deterministic generator for reproducible ids.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("TaskID")
struct TaskIDTests {
    @Test func generatedIDsHaveTheContractFormat() {
        for _ in 0..<500 {
            let id = TaskID.generate()
            #expect(id.rawValue.count == 9)
            #expect(id.rawValue.hasPrefix("mc_"))
            #expect(id.rawValue.dropFirst(3).allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
            #expect(TaskID(rawValue: id.rawValue) == id)
            #expect(id.description == id.rawValue)
        }
    }

    @Test func generationIsRandomAndReproducibleWithASeed() {
        let ids = Set((0..<1000).map { _ in TaskID.generate() })
        #expect(ids.count > 990)

        var a = SplitMix64(state: 42)
        var b = SplitMix64(state: 42)
        let first = (0..<5).map { _ in TaskID.generate(using: &a) }
        let second = (0..<5).map { _ in TaskID.generate(using: &b) }
        #expect(first == second)
        #expect(Set(first).count == 5)
    }

    @Test(arguments: ["mc_abc123", "mc_000000", "mc_zzzzzz", "mc_a1b2c3"])
    func acceptsValid(_ raw: String) {
        #expect(TaskID(rawValue: raw)?.rawValue == raw)
        #expect(TaskID.isValid(raw))
    }

    @Test(arguments: ["", "mc_", "mc_abc12", "mc_abc1234", "MC_abc123", "mc_ABC123", "mc_abc-12", "mx_abc123", "mc_abc 12", "mc_ábc123", " mc_abc123", "abc123"])
    func rejectsInvalid(_ raw: String) {
        #expect(TaskID(rawValue: raw) == nil)
        #expect(!TaskID.isValid(raw))
    }

    @Test func codableAsPlainStringWithValidation() throws {
        let id = try #require(TaskID(rawValue: "mc_k2x9q1"))
        #expect(try Fixture.json(id) == #""mc_k2x9q1""#)
        #expect(try Fixture.roundTrip(id) == id)
        #expect(throws: DecodingError.self) { try Fixture.decode(TaskID.self, from: #""mc_BAD""#) }
    }

    @Test func generateAvoidingSkipsTakenIDs() {
        var probe = SplitMix64(state: 99)
        let first = TaskID.generate(using: &probe)
        var generator = SplitMix64(state: 99)
        let next = TaskID.generate(avoiding: [first], using: &generator)
        #expect(next != first, "the colliding first draw is skipped")
        let taken = Set((0..<200).map { _ in TaskID.generate() })
        #expect(!taken.contains(TaskID.generate(avoiding: taken)))
    }

    @Test func ordering() throws {
        let a = try #require(TaskID(rawValue: "mc_aaaaaa"))
        let b = try #require(TaskID(rawValue: "mc_bbbbbb"))
        #expect(a < b)
    }
}
