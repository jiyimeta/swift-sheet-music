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

    @Test func chordStoresArticulations() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [ChordArticulation(kind: .staccato, anchor: .above)]
        )
        #expect(chord.articulations.count == 1)
        #expect(chord.articulations[0].kind == .staccato)
    }

    @Test func chordDefaultsToEmptyArticulations() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)])
        )
        #expect(chord.articulations.isEmpty)
    }
}
