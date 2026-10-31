import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// A tie end that still finds no partner is dropped, as MuseScore drops it, and reported under a code that says what
/// shape the broken tie had — so the field data a host collects per code tells the causes apart. Each message carries
/// the raw `<location>` deltas the file wrote.
struct UnpairedTieDiagnosticTests {
    private typealias Fixture = CrossStaffTieTests

    private static func codes(_ xml: String) throws -> [String] {
        try Fixture.unpaired(Fixture.parse(xml)).map(\.code)
    }

    private static func messages(_ xml: String) throws -> [String] {
        try Fixture.unpaired(Fixture.parse(xml)).map(\.message)
    }

    private static func oneStaff(_ measures: String..., version: String = "4.40") -> String {
        """
        <museScore version="\(version)">
          <Score>
            <Division>480</Division>
            <Part><Staff id="1"/><Instrument><Channel/></Instrument></Part>
            <Staff id="1">
        \(measures.joined())
            </Staff>
          </Score>
        </museScore>
        """
    }

    @Test func aTieIntoTheOtherStaffWithNothingThereIsReportedAsCrossStaff() throws {
        let tie = Fixture.next("<staves>1</staves><fractions>1/4</fractions>")
        let xml = Fixture.piano(
            Fixture.measure(
                Fixture.timeSig, Fixture.chord("quarter", Fixture.note(60, tie)), Fixture.rest("quarter"),
                Fixture.rest("half"),
            ),
            Fixture.measure(
                Fixture.timeSig, Fixture.rest("quarter"), Fixture.chord("quarter", Fixture.note(62)),
                Fixture.rest("half"),
            ),
        )
        #expect(try Self.codes(xml) == ["mscx.tie.unpairedSide.crossStaff"])
        let message = try #require(try Self.messages(xml).first)
        #expect(message.contains("staves 1"))
        #expect(message.contains("fractions 1/4"))
        #expect(message.contains("tieForward"))
    }

    @Test func aTieIntoAnotherVoiceWithNothingThereIsReportedAsCrossVoice() throws {
        let xml = Self.oneStaff(
            Fixture.measure(
                Fixture.timeSig,
                Fixture.chord("whole", Fixture.note(60, Fixture.next("<voices>1</voices><measures>1</measures>"))),
            ),
            "<Measure><voice>\(Fixture.chord("whole", Fixture.note(64)))</voice>"
                + "<voice>\(Fixture.chord("whole", Fixture.note(67)))</voice></Measure>",
        )
        #expect(try Self.codes(xml) == ["mscx.tie.unpairedSide.crossVoice"])
        #expect(try Self.messages(xml).first?.contains("voices 1") == true)
    }

    @Test func aTieOverTheSamePitchStruckAgainIsReportedAsDistant() throws {
        // C4 names the C4 half a half-note later, but a C4 struck afresh sits between them.
        let xml = Self.oneStaff(Fixture.measure(
            Fixture.timeSig,
            Fixture.chord("quarter", Fixture.note(60, Fixture.next("<fractions>1/2</fractions>"))),
            Fixture.chord("quarter", Fixture.note(60)),
            Fixture.chord("half", Fixture.note(60, Fixture.prev("<fractions>-1/2</fractions>"))),
        ))
        #expect(try Self.codes(xml) == [
            "mscx.tie.unpairedSide.distant", "mscx.tie.unpairedSide.distant",
        ])
        #expect(try Self.messages(xml).first?.contains("fractions 1/2") == true)
    }

    @Test func aTieNamingTheRestBehindItIsReportedAsNoPartner() throws {
        // 泡沫サタデーナイト.mscz's shape: the stale `<next>` names the rest that follows the note.
        let xml = Self.oneStaff(Fixture.measure(
            Fixture.timeSig,
            Fixture.chord("half", Fixture.note(60, Fixture.next("<fractions>1/2</fractions>"))),
            Fixture.rest("half"),
        ))
        #expect(try Self.codes(xml) == ["mscx.tie.unpairedSide.noPartner"])
    }

    @Test func aDetachedTieTheFileContradictsIsNotTaken() throws {
        // A stale `<next>` naming the rest behind its note, and a later C4 whose `<prev>` names a chord that is not
        // there. The shared rule would tie the two over the rest; the file pairs neither with the other, so MuseScore
        // drops both — and so does the reader.
        let stray = Fixture.prev("<measures>-1</measures><fractions>1/4</fractions>")
        let xml = Self.oneStaff(
            Fixture.measure(
                Fixture.timeSig,
                Fixture.chord("half", Fixture.note(60, Fixture.next("<fractions>1/2</fractions>"))),
                Fixture.rest("half"),
            ),
            Fixture.measure(Fixture.chord("whole", Fixture.note(60, stray))),
        )
        let result = try Fixture.parse(xml)
        #expect(Fixture.unpaired(result).map(\.code) == [
            "mscx.tie.unpairedSide.noPartner", "mscx.tie.unpairedSide.distant",
        ])
        let notes = Fixture.notes(result.score, staff: 0)
        #expect(notes.allSatisfy { $0.tieForward == nil && $0.tieBack == nil })
    }

    @Test func aLegacyTieWithNoEndIsReportedAsNoLocation() throws {
        let xml = Self.oneStaff(
            """
            <Measure>
              <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
              <Chord><durationType>half</durationType>
                <Note><Tie id="1"></Tie><pitch>60</pitch><tpc>14</tpc></Note>
              </Chord>
              <Chord><durationType>half</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
            </Measure>
            """,
            version: "2.06",
        )
        #expect(try Self.codes(xml) == ["mscx.tie.unpairedSide.noLocation"])
    }

    // MARK: - MuseScore 5

    /// MuseScore 5 writes a tie once, as a `<Tie>` on its END note naming both notes by `<eid>`
    /// (`mnx/tests/data/mscx_reference_examples/ties_ref.mscx`).
    private static func museScore5(startElement: String) -> String {
        oneStaff(
            """
            <Measure><voice>
              <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
              <Chord><durationType>half</durationType>
                <Note><eid>L_L</eid><pitch>76</pitch><tpc>18</tpc></Note>
              </Chord>
              <Chord><durationType>half</durationType>
                <Note><eid>N_N</eid>
                  <Tie><startElement>\(startElement)</startElement><endElement>N_N</endElement><eid>O_O</eid></Tie>
                  <pitch>76</pitch><tpc>18</tpc>
                </Note>
              </Chord>
            </voice></Measure>
            """,
            version: "5.00",
        )
    }

    @Test func aMuseScore5TieIsReadByItsElementIDs() throws {
        let result = try Fixture.parse(Self.museScore5(startElement: "L_L"))
        #expect(Fixture.unpaired(result).isEmpty)
        let notes = Fixture.notes(result.score, staff: 0)
        #expect(notes.map { $0.tieForward != nil } == [true, false])
        #expect(notes.map { $0.tieBack != nil } == [false, true])
    }

    @Test func aMuseScore5TieWithAMissingStartIsReportedAsMuseScore5() throws {
        #expect(try Self.codes(Self.museScore5(startElement: "Z_Z")) == ["mscx.tie.unpairedSide.museScore5"])
    }
}
