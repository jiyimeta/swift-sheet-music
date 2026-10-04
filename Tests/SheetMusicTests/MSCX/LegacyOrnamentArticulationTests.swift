import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// MuseScore 3 (and 4.0) wrote an ornament as an `<Articulation>` carrying an ornament SymId. MuseScore 4.1 turns
/// each into an `<Ornament>` on load (`CompatUtils::replaceOldWithNewOrnaments`); read as an articulation, it decoded
/// as `.unknown` and was neither drawn nor played.
@Suite("MuseScore 3 ornament articulations")
struct LegacyOrnamentArticulationTests {
    private func parseChord(_ inner: String) throws -> Chord {
        let root = try XMLTreeParser.parse(Data("<Chord>\(inner)</Chord>".utf8))
        return try Chord.decode(root)
    }

    @Test("an ornament SymId under <Articulation> decodes as the ornament", arguments: [
        ("ornamentTrill", ChordOrnament.Kind.trill), ("ornamentMordent", .mordent), ("ornamentTurn", .turn),
        ("ornamentTurnInverted", .turnInverted), ("ornamentShortTrill", .shortTrill),
        ("ornamentPrallMordent", .prallMordent), ("ornamentTremblementCouperin", .tremblementCouperin),
    ] as [(String, ChordOrnament.Kind)])
    func ornamentSymIdBecomesAnOrnament(subtype: String, kind: ChordOrnament.Kind) throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>\(subtype)</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.ornaments.map(\.kind) == [kind])
        #expect(chord.articulations.isEmpty)
    }

    /// The ornament-only state MuseScore 3 wrote on the articulation travels with it, as `replaceOldWithNewOrnaments`
    /// copies the style and the play flag; the real articulations beside it stay articulations.
    @Test("the style and play flag carry over, and articulations stay articulations")
    func stateCarriesOverBesideRealArticulations() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>articStaccatoBelow</subtype></Articulation>
        <Articulation>
          <subtype>ornamentMordent</subtype>
          <ornamentStyle>baroque</ornamentStyle>
          <play>0</play>
        </Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [ChordArticulation(kind: .staccato, anchor: .below)])
        let ornament = try #require(chord.ornaments.first)
        #expect(chord.ornaments.count == 1)
        #expect(ornament.kind == .mordent)
        #expect(ornament.ornamentStyle == .baroque)
        #expect(ornament.plays == false)
    }

    /// MuseScore's list also moves `brassMuteClosed`, but this package models the stopped mark as an articulation —
    /// MuseScore 4's own Articulations palette writes it as one — so it stays where it is.
    @Test("brassMuteClosed stays an articulation")
    func stoppedMarkStaysAnArticulation() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>brassMuteClosed</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.articulations == [ChordArticulation(kind: .muteClosed)])
        #expect(chord.ornaments.isEmpty)
    }

    /// Written back, it is the `<Ornament>` MuseScore 4 would save — and the MuseScore 3 shape again for a v3 target.
    @Test("it writes back as an <Ornament>, or as the <Articulation> for a v3 target")
    func writesBackAsAnOrnament() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>ornamentTrill</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        let v4 = chord.encodeAsChord(eid: .invalid)
        #expect(v4.all("Ornament").compactMap { $0.first("subtype")?.text } == ["ornamentTrill"])
        #expect(v4.all("Articulation").isEmpty)
        let v3 = chord.encodeAsChord(eid: .invalid, options: MSCXEncoderOptions(targetVersion: .v3))
        #expect(v3.all("Articulation").compactMap { $0.first("subtype")?.text } == ["ornamentTrill"])
    }
}
