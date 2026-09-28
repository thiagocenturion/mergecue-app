import Foundation
import MergeCueCore
import Testing

@Suite("InvisibleText (S11)")
struct InvisibleTextTests {
    @Test func removesZeroWidthBidiTagsAndControls() {
        let text = "Looks\u{200B} good\u{202E}evil\u{202C} \u{2066}x\u{2069}\u{E0041}\u{00AD}\u{FEFF}\u{1B}!\nnext\tline"
        let result = InvisibleText.sanitized(text)
        #expect(result.text == "Looks goodevil x!\nnext\tline")
        #expect(result.removed["U+200B"] == 1)
        #expect(result.removed["U+202E"] == 1)
        #expect(result.removed["U+E0041"] == 1)
        #expect(result.removedCount == 9)
        #expect(result.removedSummary?.contains("U+2066") == true)
    }

    @Test func keepsOrdinaryTextAndEmojiSequences() {
        let family = "Thanks 👨‍👩‍👧 — résumé 日本語\n"
        let result = InvisibleText.sanitized(family)
        #expect(result.text == family)
        #expect(result.removedSummary == nil)
    }
}
