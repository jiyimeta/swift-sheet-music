import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct ChordArticulationTests {
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
                != ChordArticulation(kind: .staccatissimo),
        )
    }

    @Test func chordStoresArticulations() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [ChordArticulation(kind: .staccato, anchor: .above)],
        )
        #expect(chord.articulations.count == 1)
        #expect(chord.articulations[0].kind == .staccato)
    }

    @Test func chordDefaultsToEmptyArticulations() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
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
        <Articulation><subtype>articSoftAccentAbove</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .unknown(subtype: "articSoftAccentAbove")),
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

    private func encodedSubtypes(_ articulations: [ChordArticulation]) -> [String] {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: articulations,
        )
        let xml = chord.encodeAsChord()
        return xml.all("Articulation").compactMap { $0.first("subtype")?.text }
    }

    @Test func encodesDefaultAnchorAsAbove() {
        // anchor == nil should serialize as the "Above" SymId variant.
        #expect(encodedSubtypes([.init(kind: .staccato)]) == ["articStaccatoAbove"])
    }

    @Test func encodesExplicitBelowAnchor() {
        #expect(
            encodedSubtypes([.init(kind: .staccatissimo, anchor: .below)])
                == ["articStaccatissimoBelow"],
        )
    }

    @Test func encodesUnknownVerbatim() {
        // Unknown round-trips its raw string and ignores anchor.
        #expect(
            encodedSubtypes([.init(kind: .unknown(subtype: "articSoftAccentAbove"))])
                == ["articSoftAccentAbove"],
        )
    }

    @Test func articulationsEncodeBetweenDurationAndNotes() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [.init(kind: .staccato, anchor: .above)],
        )
        let xml = chord.encodeAsChord()
        let names = xml.children.map(\.name)
        let durIdx = try #require(names.firstIndex(of: "durationType"))
        let artIdx = try #require(names.firstIndex(of: "Articulation"))
        let noteIdx = try #require(names.firstIndex(of: "Note"))
        #expect(durIdx < artIdx)
        #expect(artIdx < noteIdx)
    }

    @Test func encodeDecodeRoundTripsAllKinds() throws {
        let original = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [
                .init(kind: .staccato, anchor: .above),
                .init(kind: .staccatissimo, anchor: .below),
                .init(kind: .tenuto, anchor: .above),
                .init(kind: .unknown(subtype: "articSoftAccentAbove")),
            ],
        )
        let xml = original.encodeAsChord()
        let serialized = XMLTreeSerializer.serialize(xml)
        let parsed = try XMLTreeParser.parse(serialized)
        let roundTripped = try Chord.decode(parsed)
        #expect(roundTripped.articulations == original.articulations)
    }
}
