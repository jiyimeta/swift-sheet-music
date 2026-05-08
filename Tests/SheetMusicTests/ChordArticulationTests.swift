import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
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

    private func parseChord(_ inner: String) throws -> Chord {
        let xml = "<Chord>\(inner)</Chord>"
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        return try Chord.decode(root)
    }

    @Test func decodesSingleStaccatoAbove() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articStaccatoAbove</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [ChordArticulation(kind: .staccato, anchor: .above)])
    }

    @Test func decodesMultipleArticulationsPreservingOrderAndAnchors() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articStaccatoAbove</subtype></Articulation>
        <Articulation><subtype>articTenutoBelow</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .staccato, anchor: .above),
            ChordArticulation(kind: .tenuto, anchor: .below),
        ])
    }

    @Test func decodesUnknownSubtypeAsUnknownVariant() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articAccentAbove</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .unknown(subtype: "articAccentAbove")),
        ])
    }

    @Test func decodesEmptySubtypeAsUnknownEmpty() throws {
        // MuseScore never emits this; permissive-parser convention says don't throw.
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype></subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .unknown(subtype: "")),
        ])
    }
}
