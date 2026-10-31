import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Slurs whose begin or end is a grace chord.
///
/// MuseScore writes a grace's slur exactly as it writes any chord's — the begin side inside the grace's own
/// `<Chord>`, a `<prev>` marker inside the end one — and names a grace END with `<location><grace>N</grace>`, where
/// `N` is the grace's index in its chord's run (`Location::graceIndex`, `dom/location.cpp`). The begin side lands in
/// `GraceChord.spanners`; a grace end lands in `Spanner.nextGraceIndex`.
///
/// `slur_grace_selectionfilter.mscx` is MuseScore's own
/// `src/engraving/tests/selectionfilter_data/selectionfilter_gracesandslurs.mscx`, vendored verbatim. Each of its
/// four 6/8 bars carries the same three slurs, offsets read out of the file (bar 1, `:155-302`):
///
/// - the acciaccatura E4 before the downbeat G4 → the chord at 1/8 (`<fractions>1/8</fractions>`, no `<grace>`);
/// - the acciaccatura E4 before the G4 at 2/8 → the acciaccatura D5 before the chord at 3/8
///   (`<fractions>1/8</fractions><grace>0</grace>`);
/// - the G4 at 4/8 → the acciaccatura before the chord at 5/8 (`<fractions>1/8</fractions><grace>0</grace>`).
@Suite("Grace-note slur decode")
struct GraceSlurDecodeTests {
    @Test("MuseScore's grace/slur fixture decodes with no slur dropped or re-homed")
    func fixtureDecodesWithoutSlurDiagnostics() throws {
        let result = try MSCXParser.parseWithDiagnostics(
            MSCXFixtureLoader.mscxData("slur_grace_selectionfilter"),
        )
        let codes = result.diagnostics.map(\.code)
        #expect(!codes.contains("mscx.chord.spannerDropped"))
        #expect(!codes.contains("mscx.slur.locationDropped"))
    }

    @Test("a slur begun on a grace is kept on that grace; a grace end is kept as its index")
    func fixtureSlursLandOnTheirGraces() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("slur_grace_selectionfilter"))
        let staff = try #require(score.allStaves.first?.1)
        #expect(staff.measures.count == 4)
        for measure in staff.measures {
            let chords = Self.chords(in: measure)
            #expect(chords.count == 6)
            // Grace → the chord at 1/8.
            let first = try #require(chords[0].graceNotesBefore.first)
            #expect(first.spanners == [Self.slur(fractions: 1, graceIndex: nil)])
            // Grace → the next chord's grace.
            let second = try #require(chords[2].graceNotesBefore.first)
            #expect(second.spanners == [Self.slur(fractions: 1, graceIndex: 0)])
            // Ordinary chord → the next chord's grace.
            #expect(chords[4].spanners == [Self.slur(fractions: 1, graceIndex: 0)])
            // Nothing else in the bar holds a slur begin: the `<prev>` markers carry no model state.
            let begins = chords.reduce(0) { count, chord in
                let graces = chord.graceNotesBefore.values + chord.graceNotesAfter.values
                return count + chord.spanners.count + graces.reduce(0) { $0 + $1.spanners.count }
            }
            #expect(begins == 3)
        }
    }

    /// The overwhelmingly common shape in real scores — an acciaccatura slurred into its own principal note — has no
    /// offset at all: MuseScore writes `<next><location/></next>` on the grace and `<prev><location><grace>0</grace>`
    /// on the principal. Read from `Grace_notes.mscz` in MuseScore's vtest set.
    @Test("a grace slurred into its own principal note decodes with zero offsets")
    func graceIntoItsOwnPrincipal() throws {
        let score = try MSCXParser.parse(Data(Self.graceIntoPrincipal.utf8))
        let chord = try #require(Self.chords(in: score.parts[0].staves[0].measures[0]).first)
        let grace = try #require(chord.graceNotesBefore.first)
        #expect(grace.spanners.count == 1)
        let slur = try #require(grace.spanners.first)
        #expect(slur.kind == .slur)
        #expect(slur.nextMeasuresOffset == 0)
        #expect(slur.nextFractionsOffset == nil)
        #expect(slur.nextGraceIndex == nil)
        // The principal's `<prev>` marker carries no model state.
        #expect(chord.spanners.isEmpty)
    }

    /// One chord's slur into its own after-grace (a trill's Nachschlag): MuseScore writes `<grace>N</grace>` with no
    /// offset on the main chord and a bare `<prev><location/>` on the grace. Shape from `We Are Young(short).mscz`.
    @Test("a chord slurred into its own after-grace keeps the grace index")
    func chordIntoItsOwnAfterGrace() throws {
        let score = try MSCXParser.parse(Data(Self.chordIntoAfterGrace.utf8))
        let chord = try #require(Self.chords(in: score.parts[0].staves[0].measures[0]).first)
        #expect(chord.graceNotesAfter.count == 1)
        #expect(chord.spanners == [Spanner(kind: .slur, rawType: "Slur", nextGraceIndex: 0)])
        #expect(chord.grace(atMuseScoreGraceIndex: 0)?.side == .after)
    }

    // MARK: - Helpers

    static func slur(fractions eighths: Int, graceIndex: Int?) -> Spanner {
        Spanner(
            kind: .slur, rawType: "Slur",
            nextFractionsOffset: Fraction(numerator: eighths, denominator: 8),
            nextGraceIndex: graceIndex,
        )
    }

    static func chords(in measure: Measure) -> [Chord] {
        measure.voices[0].elements.compactMap { element in
            guard case let .chord(chord) = element, !chord.notes.isEmpty else { return nil }
            return chord
        }
    }

    static func document(voice: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Part id="1">
              <Staff id="1"/>
              <Instrument id="piano"><longName>Piano</longName></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
        \(voice)
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
    }

    static let graceIntoPrincipal = document(voice: """
      <Chord>
        <durationType>eighth</durationType>
        <Spanner type="Slur">
          <Slur/>
          <next>
            <location/>
          </next>
        </Spanner>
        <acciaccatura/>
        <Note><pitch>74</pitch><tpc>16</tpc></Note>
      </Chord>
      <Chord>
        <durationType>whole</durationType>
        <Spanner type="Slur">
          <prev>
            <location>
              <grace>0</grace>
            </location>
          </prev>
        </Spanner>
        <Note><pitch>72</pitch><tpc>14</tpc></Note>
      </Chord>
    """)

    static let chordIntoAfterGrace = document(voice: """
      <Chord>
        <durationType>16th</durationType>
        <Spanner type="Slur">
          <prev>
            <location/>
          </prev>
        </Spanner>
        <grace16after/>
        <Note><pitch>71</pitch><tpc>19</tpc></Note>
      </Chord>
      <Chord>
        <durationType>whole</durationType>
        <Spanner type="Slur">
          <Slur/>
          <next>
            <location>
              <grace>0</grace>
            </location>
          </next>
        </Spanner>
        <Note><pitch>72</pitch><tpc>14</tpc></Note>
      </Chord>
    """)
}
