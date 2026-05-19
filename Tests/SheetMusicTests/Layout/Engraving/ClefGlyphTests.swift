import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("ClefGlyph")
struct ClefGlyphTests {
    @Test func trebleMapsToGClef() {
        let (cp, dy) = ClefGlyph.glyph(for: .treble)
        #expect(cp == SMuFLCodepoint.gClef)
        #expect(dy == 1)
    }

    @Test func bassMapsToFClefWithNegativeOffset() {
        let (cp, dy) = ClefGlyph.glyph(for: .bass)
        #expect(cp == SMuFLCodepoint.fClef)
        #expect(dy == -1)
    }

    @Test func cClefFamilySharesCodepointAndDiffersInOffset() {
        let (sopranoCP, sopranoDy) = ClefGlyph.glyph(for: .soprano)
        let (altoCP, altoDy) = ClefGlyph.glyph(for: .alto)
        let (tenorCP, tenorDy) = ClefGlyph.glyph(for: .tenor)
        let (baritoneCP, baritoneDy) = ClefGlyph.glyph(for: .baritone)
        #expect(sopranoCP == SMuFLCodepoint.cClef)
        #expect(altoCP == SMuFLCodepoint.cClef)
        #expect(tenorCP == SMuFLCodepoint.cClef)
        #expect(baritoneCP == SMuFLCodepoint.cClef)
        #expect(sopranoDy == 2)
        #expect(altoDy == 0)
        #expect(tenorDy == -1)
        #expect(baritoneDy == -2)
    }

    @Test func everyClefHasMapping() {
        // Exhaustiveness guard: if NotatedClef gains a case, this loop
        // forces ClefGlyph.glyph(for:) to handle it (the switch is
        // already exhaustive — this just asserts no case crashes).
        for clef in NotatedClef.allCases {
            _ = ClefGlyph.glyph(for: clef)
        }
    }
}
