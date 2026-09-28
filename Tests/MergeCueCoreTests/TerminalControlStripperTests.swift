import Foundation
import MergeCueCore
import Testing

@Suite("TerminalControlStripper + redaction of coloured output")
struct TerminalControlStripperTests {
    static let esc = "\u{1B}"

    @Test func stripsSGRAndCursorSequences() {
        let input = "\(Self.esc)[1;31merror\(Self.esc)[0m: build \(Self.esc)[2Kfailed\(Self.esc)[?25l"
        #expect(TerminalControlStripper.strip(input) == "error: build failed")
    }

    @Test func stripsOSCClipboardAndHyperlinks() {
        // OSC 52 (clipboard write) terminated by BEL, OSC 8 hyperlink terminated by ST (ESC \).
        let osc52 = "before\(Self.esc)]52;c;Y3VybCBldmlsLnNoIHwgc2g=\u{07}after"
        #expect(TerminalControlStripper.strip(osc52) == "beforeafter")
        let osc8 = "\(Self.esc)]8;;https://evil.example\(Self.esc)\\click\(Self.esc)]8;;\(Self.esc)\\ here"
        #expect(TerminalControlStripper.strip(osc8) == "click here")
        // 8-bit C1 forms.
        #expect(TerminalControlStripper.strip("a\u{9D}52;c;AAAA\u{9C}b\u{9B}31mc") == "abc")
    }

    @Test func stripsDCSAndOtherEscapes() {
        #expect(TerminalControlStripper.strip("x\(Self.esc)P1$r0m\(Self.esc)\\y") == "xy")
        #expect(TerminalControlStripper.strip("x\(Self.esc)(By\(Self.esc)=z\(Self.esc)7") == "xyz")
    }

    @Test func keepsNewlinesAndTabsAndNormalizesCarriageReturns() {
        #expect(TerminalControlStripper.strip("a\tb\nc") == "a\tb\nc")
        #expect(TerminalControlStripper.strip("line1\r\nline2\r\n") == "line1\nline2\n")
        #expect(TerminalControlStripper.strip("10%\r100%") == "10%\n100%")
        #expect(TerminalControlStripper.strip("bell\u{07}nul\u{00}del\u{7F}bs\u{08}") == "bellnuldelbs")
    }

    @Test func unterminatedStringOnlyLosesItsIntroducer() {
        #expect(TerminalControlStripper.strip("a\(Self.esc)]0;title without end") == "a0;title without end")
    }

    @Test func leavesPlainTextAlone() {
        let text = "résumé naïve — ✅ 🚀 日本語\n\tindent"
        #expect(TerminalControlStripper.strip(text) == text)
        #expect(!TerminalControlStripper.containsControls(text))
    }

    @Test func manyUnterminatedIntroducersStayLinear() {
        let input = String(repeating: "\(Self.esc)]x", count: 100_000)
        let elapsed = ContinuousClock().measure { _ = TerminalControlStripper.strip(input) }
        #expect(elapsed < .milliseconds(500), "\(elapsed)")
        let csi = String(repeating: "\(Self.esc)[1;2;3", count: 100_000)
        let elapsedCSI = ContinuousClock().measure { _ = TerminalControlStripper.strip(csi) }
        #expect(elapsedCSI < .milliseconds(500), "\(elapsedCSI)")
    }

    // MARK: Redaction of coloured tokens

    @Test func redactorMasksTokenRightAfterAnSGRSequence() {
        let token = "ghp_1234567890abcdefghijABCDEFGHIJ1234"
        let coloured = "\(Self.esc)[1m\(token)\(Self.esc)[0m"
        #expect(!SecretRedactor.redact(coloured).contains("1234567890abcdefghij"))
        #expect(!SecretRedactor.redact("\(Self.esc)[38;5;196mglpat-AbCdEfGhIjKlMnOpQrSt").contains("AbCdEfGhIjKlMnOpQrSt"))
    }

    @Test func logExcerptAndUntrustedTextStripBeforeRedacting() {
        let token = "ghp_1234567890abcdefghijABCDEFGHIJ1234"
        let log = "step\n\(Self.esc)[32mTOKEN\(Self.esc)[0m \(Self.esc)[1m\(token)\(Self.esc)[0m\n\(Self.esc)]52;c;ZXZpbA==\u{07}done"
        let excerpt = LogExcerpt.make(rawLog: log, maxBytes: 4096)
        #expect(!excerpt.text.contains("1234567890abcdefghij"))
        #expect(!excerpt.text.contains("\u{1B}"))
        #expect(!excerpt.text.contains("ZXZpbA"))
        #expect(excerpt.text.contains("done"))

        let body = UntrustedText.bounded(source: UntrustedText.Source.reviewComment, text: "see \(Self.esc)[1m\(token)\u{07}", maxBytes: 1024)
        #expect(body.text == "see ghp_[REDACTED]")
    }

    @Test func logExcerptDropsNonWebLogURLs() {
        #expect(LogExcerpt.make(rawLog: "x", maxBytes: 64, fullLogURL: URL(string: "file:///etc/passwd")).fullLogURL == nil)
        #expect(LogExcerpt.make(rawLog: "x", maxBytes: 64, fullLogURL: URL(string: "https://ci.example/log")).fullLogURL != nil)
    }

    /// New prefixes (S4) — each must be masked with its prefix kept for context.
    static let newPrefixes: [(String, String, String)] = [
        ("OPENAI_API_KEY is sk-proj-AbCdEf0123456789_ghIJklMNopQRstuvWX-yz here", "AbCdEf0123456789_gh", "sk-proj-"),
        ("key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abc end", "AbCdEfGhIjKlMnOpQrSt", "sk-ant-api03-"),
        ("legacy sk-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd end", "AbCdEfGhIjKlMnOpQrSt", "legacy sk-"),
        ("stripe sk_live_51HAbCdEfGhIjKlMnOpQrSt end", "51HAbCdEfGhIjKl", "sk_live_"),
        ("restricted rk_live_51HAbCdEfGhIjKlMnOpQrSt end", "51HAbCdEfGhIjKl", "rk_live_"),
        ("//registry.npmjs.org/:_authToken npm_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", "AbCdEfGhIjKlMnOpQrSt", "npm_"),
        ("docker login -p dckr_pat_AbCdEfGhIjKlMnOpQrStUvWx end", "AbCdEfGhIjKlMnOpQrSt", "dckr_pat_"),
        ("maps AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz0123456 end", "SyAbCdEfGhIjKlMnOpQr", "AIza"),
        ("post to https://hooks.slack.com/services/T0000/B0000/AbCdEfGhIjKlMnOp now", "AbCdEfGhIjKlMnOp", "https://hooks.slack.com/services/"),
    ]

    @Test(arguments: newPrefixes)
    func masksNewPrefixes(_ input: String, secret: String, kept: String) {
        let output = SecretRedactor.redact(input)
        #expect(!output.contains(secret), "not redacted: \(output)")
        #expect(output.contains(kept), "context lost: \(output)")
        #expect(SecretRedactor.redact(output) == output)
    }

    @Test(arguments: ["scikit-learn sk-learn is a package", "npm_modules folder", "use AIza keys", "sk_live_ prefix", "task-sk-1"])
    func newPrefixesLeaveProseAlone(_ input: String) {
        #expect(SecretRedactor.redact(input) == input)
    }

    /// Redaction of hostile coloured input stays linear (DECISIONS D21).
    @Test(arguments: ["\u{1B}[1m", "\u{1B}[1mghp_", "sk-proj-", "\u{1B}[;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;m", "AIza", "npm_x"])
    func colouredHostileInputStaysFast(_ unit: String) {
        let input = String(repeating: unit, count: 64 * 1024 / unit.utf8.count)
        let elapsed = ContinuousClock().measure {
            _ = SecretRedactor.redact(input)
            _ = LogExcerpt.make(rawLog: input, maxBytes: 16 * 1024)
        }
        #expect(elapsed < .milliseconds(500), "\(unit.debugDescription): \(elapsed)")
    }
}
