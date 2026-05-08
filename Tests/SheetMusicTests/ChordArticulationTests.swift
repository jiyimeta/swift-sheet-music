import Foundation
@testable import SheetMusicCore
import Testing

@Suite struct ChordArticulationTests {
    @Test func constructsKnownKindWithAnchor() {
        let art = ChordArticulation(kind: .staccato, anchor: .above)
        #expect(art.kind == .staccato)
        #expect(art.anchor == .above)
    }

    @Test func unknownPreservesRawSubtype() {
        let art = ChordArticulation(kind: .unknown(subtype: "articAccentAbove"))
        #expect(art.kind == .unknown(subtype: "articAccentAbove"))
        #expect(art.anchor == nil)
    }

    @Test func equalityIsValueBased() {
        let tenutoBelow = ChordArticulation(kind: .tenuto, anchor: .below)
        #expect(tenutoBelow == ChordArticulation(kind: .tenuto, anchor: .below))
        #expect(
            ChordArticulation(kind: .staccato)
                != ChordArticulation(kind: .staccatissimo)
        )
    }
}
