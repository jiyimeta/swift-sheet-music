import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite struct ChordArticulationVelocityTests {
    private func parseChord(_ inner: String) throws -> Chord {
        let xml = "<Chord>\(inner)</Chord>"
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        return try Chord.decode(root)
    }

    @Test func decodesAccentAbove() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articAccentAbove</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .accent, anchor: .above),
        ])
    }

    @Test func decodesMarcatoBelow() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articMarcatoBelow</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .marcato, anchor: .below),
        ])
    }

    @Test func decodesAccentStaccatoCombinedNotPlainAccent() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articAccentStaccatoAbove</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .accentStaccato, anchor: .above),
        ])
    }

    @Test func decodesMarcatoStaccatoBelow() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articMarcatoStaccatoBelow</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [
            ChordArticulation(kind: .marcatoStaccato, anchor: .below),
        ])
    }

    private func encodedSubtypes(_ articulations: [ChordArticulation]) -> [String] {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: articulations
        )
        let xml = chord.encodeAsChord()
        return xml.all("Articulation").compactMap { $0.first("subtype")?.text }
    }

    @Test func encodesAllNewKinds() {
        #expect(
            encodedSubtypes([
                .init(kind: .accent, anchor: .above),
                .init(kind: .marcato, anchor: .below),
                .init(kind: .accentStaccato, anchor: .above),
                .init(kind: .marcatoStaccato, anchor: .below),
            ]) == [
                "articAccentAbove",
                "articMarcatoBelow",
                "articAccentStaccatoAbove",
                "articMarcatoStaccatoBelow",
            ]
        )
    }

    @Test func encodesNilAnchorAsAbove() {
        #expect(
            encodedSubtypes([.init(kind: .accent)]) == ["articAccentAbove"]
        )
    }

    @Test func roundTripsAllNewKinds() throws {
        let original = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [
                .init(kind: .accent, anchor: .above),
                .init(kind: .marcato, anchor: .below),
                .init(kind: .accentStaccato, anchor: .above),
                .init(kind: .marcatoStaccato, anchor: .below),
            ]
        )
        let xml = original.encodeAsChord()
        let serialized = XMLTreeSerializer.serialize(xml)
        let parsed = try XMLTreeParser.parse(serialized)
        let roundTripped = try Chord.decode(parsed)
        #expect(roundTripped.articulations == original.articulations)
    }
}
