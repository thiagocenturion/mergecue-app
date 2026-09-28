import Foundation
import Testing
@testable import MergeCueUI

/// WCAG AA over the theme tokens, in light, dark and both Increase Contrast appearances: 4.5:1 for text, 3:1 for
/// control boundaries, the focus ring and glyphs on status fills.
@Suite("Theme contrast")
@MainActor
struct ContrastTests {
    typealias Appearance = (name: String, dark: Bool, highContrast: Bool)
    static let appearances: [Appearance] = [("light", false, false), ("dark", true, false),
                                            ("light HC", false, true), ("dark HC", true, true)]

    static func hex(_ token: ColorToken, _ appearance: Appearance) -> UInt32 {
        token.resolved(dark: appearance.dark, highContrast: appearance.highContrast).hex
    }

    /// A translucent token composited over an opaque surface.
    static func flattened(_ token: ColorToken, over surface: ColorToken, _ appearance: Appearance) -> UInt32 {
        let value = token.resolved(dark: appearance.dark, highContrast: appearance.highContrast)
        return Contrast.composite(value.hex, alpha: value.alpha, over: hex(surface, appearance))
    }

    @Test func contrastMathMatchesKnownValues() {
        #expect(abs(Contrast.ratio(0xFFFFFF, 0x000000) - 21) < 0.01)
        #expect(abs(Contrast.ratio(0xFFFFFF, 0xFFFFFF) - 1) < 0.001)
        // The audit's figures for the old tokens.
        #expect(abs(Contrast.ratio(0xFFFFFF, 0x38C8F5) - 1.95) < 0.01)
        #expect(Contrast.ratio(0x8891A3, 0xFFFFFF) < 4.5, "old textTertiary failed")
    }

    @Test func textTokensReadOnEverySurface() {
        for appearance in Self.appearances {
            for (textName, text) in [("textPrimary", Palette.textPrimary), ("textSecondary", Palette.textSecondary),
                                     ("textTertiary", Palette.textTertiary)] {
                for (surfaceName, surface) in Palette.surfaces {
                    let ratio = Contrast.ratio(Self.hex(text, appearance), Self.hex(surface, appearance))
                    #expect(ratio >= 4.5, "\(textName) on \(surfaceName) (\(appearance.name)): \(ratio)")
                }
            }
        }
    }

    @Test func statusTextReadsOnSurfacesAndOnItsTint() {
        for appearance in Self.appearances {
            for pair in Palette.statusPairs {
                let text = Self.hex(pair.text, appearance)
                for (surfaceName, surface) in Palette.surfaces {
                    let ratio = Contrast.ratio(text, Self.hex(surface, appearance))
                    #expect(ratio >= 4.5, "\(pair.name)Text on \(surfaceName) (\(appearance.name)): \(ratio)")
                }
                // Chips, pills, tinted buttons and badges: the status colour at up to 14 % over the card.
                for (surfaceName, surface) in Palette.tintedSurfaces {
                    let tint = Contrast.composite(Self.hex(pair.fill, appearance), alpha: 0.14, over: Self.hex(surface, appearance))
                    let ratio = Contrast.ratio(text, tint)
                    #expect(ratio >= 4.5, "\(pair.name)Text on its tint over \(surfaceName) (\(appearance.name)): \(ratio)")
                }
            }
        }
    }

    @Test func whiteTextReadsAcrossTheActionGradient() {
        let stops = Palette.actionStops
        for index in stops.indices.dropLast() {
            for step in 0...20 {
                let color = Contrast.interpolate(stops[index], stops[index + 1], Double(step) / 20)
                let ratio = Contrast.ratio(0xFFFFFF, color)
                #expect(ratio >= 4.5, "white on #\(String(color, radix: 16)): \(ratio)")
            }
        }
        for stop in Palette.selectedChipStops {
            #expect(Contrast.ratio(0xFFFFFF, stop) >= 4.5)
        }
        // The decorative brand gradient is not text-safe (why actionStops exists).
        #expect(Palette.brandStops.contains { Contrast.ratio(0xFFFFFF, $0) < 4.5 })
    }

    @Test func controlBoundariesAndFocusRingAreVisible() {
        for appearance in Self.appearances {
            for (surfaceName, surface) in Palette.controlSurfaces {
                let border = Contrast.ratio(Self.hex(Palette.controlBorder, appearance), Self.hex(surface, appearance))
                #expect(border >= 3, "controlBorder on \(surfaceName) (\(appearance.name)): \(border)")
            }
            for (surfaceName, surface) in Palette.surfaces {
                let ring = Contrast.ratio(Self.hex(Palette.focusRing, appearance), Self.hex(surface, appearance))
                #expect(ring >= 3, "focusRing on \(surfaceName) (\(appearance.name)): \(ring)")
            }
        }
    }

    @Test func glyphsOnStatusFillsAreVisible() {
        for appearance in Self.appearances {
            let glyph = Self.hex(Palette.onStatusFill, appearance)
            for pair in Palette.statusPairs {
                let ratio = Contrast.ratio(glyph, Self.hex(pair.fill, appearance))
                #expect(ratio >= 3, "glyph on \(pair.name) (\(appearance.name)): \(ratio)")
            }
        }
    }

    @Test func diffAndCodeTextRead() {
        for appearance in Self.appearances.prefix(2) {
            for base in [Palette.surface, Palette.surfaceSunken] {
                let added = Self.flattened(Palette.diffAddedBackground, over: base, appearance)
                let removed = Self.flattened(Palette.diffRemovedBackground, over: base, appearance)
                #expect(Contrast.ratio(Self.hex(Palette.diffAddedText, appearance), added) >= 4.5)
                #expect(Contrast.ratio(Self.hex(Palette.diffRemovedText, appearance), removed) >= 4.5)
                #expect(Contrast.ratio(Self.hex(Palette.textPrimary, appearance), added) >= 4.5)
                #expect(Contrast.ratio(Self.hex(Palette.textPrimary, appearance), removed) >= 4.5)
                #expect(Contrast.ratio(Self.hex(Palette.codeKeyword, appearance), Self.hex(base, appearance)) >= 4.5)
                #expect(Contrast.ratio(Self.hex(Palette.codeType, appearance), Self.hex(base, appearance)) >= 4.5)
            }
        }
    }

    @Test func increaseContrastNeverLowersContrast() {
        for dark in [false, true] {
            let regular: Appearance = (dark ? "dark" : "light", dark, false)
            let high: Appearance = (regular.name + " HC", dark, true)
            for token in [Palette.textSecondary, Palette.textTertiary, Palette.controlBorder] {
                for (_, surface) in Palette.surfaces {
                    #expect(Contrast.ratio(Self.hex(token, high), Self.hex(surface, high))
                            >= Contrast.ratio(Self.hex(token, regular), Self.hex(surface, regular)))
                }
            }
            for token in [Palette.border, Palette.divider, Palette.borderStrong] {
                let surface = Palette.surface
                #expect(Contrast.ratio(Self.flattened(token, over: surface, high), Self.hex(surface, high))
                        > Contrast.ratio(Self.flattened(token, over: surface, regular), Self.hex(surface, regular)))
            }
        }
    }
}
