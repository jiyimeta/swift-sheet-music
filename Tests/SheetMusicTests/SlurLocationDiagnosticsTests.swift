import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `mscx.slur.locationDropped` — the diagnostic for `<next><location>` fields
/// a chord-anchored slur carries and this model cannot hold.
///
/// MuseScore's `Location` has six fields and one writer emits them all —
/// `staves, voices, measures, fractions, grace, notes` (3.6.2
/// `Location::write`, `libmscore/location.cpp:52-63`; master
/// `TWrite::write(const Location*, …)`, `rw/write/twrite.cpp:2229-2243`, which
/// adds `timeTick`). `Spanner.decode` reads two of them. The other four are
/// real data, so per the repository's diagnostics policy they are announced
/// rather than dropped in silence.
///
/// Split out of `SlurDecodeTests` only to keep that file under the 400-line
/// limit; these belong to the same decode surface.
@Suite("Chord-anchored slur <location> diagnostics")
struct SlurLocationDiagnosticsTests {
    // MARK: - Fixture gate

    /// The MS3 fixture's one known loss, gated as an exact code list so it
    /// can neither grow nor silently disappear.
    ///
    /// `slur_ms3_exchangevoices.mscx:221-230` holds a slur begun in bar 2's
    /// second voice and ended in the first, written as
    /// `<next><location><voices>-1</voices><fractions>1/4</fractions>`. The
    /// model has no `<voices>` field, so the voice hop is dropped and the
    /// encoder can only re-home the `<prev>` inside the begin side's own voice
    /// — the slur's end moves. That is real data loss, so it warns
    /// (`mscx.slur.locationDropped`) rather than passing silently.
    ///
    /// Exactly one diagnostic: the score's other two slurs are same-voice and
    /// their `<location>`s hold nothing but `measures` / `fractions`.
    @Test("the MS3 fixture warns once, for its cross-voice slur's <voices>")
    func ms3FixtureWarnsOnlyOnTheVoiceHop() throws {
        let result = try MSCXParser.parseWithDiagnostics(
            MSCXFixtureLoader.mscxData("slur_ms3_exchangevoices"),
        )
        #expect(result.diagnostics.map(\.code) == ["mscx.slur.locationDropped"])
        #expect(result.diagnostics.first?.message.contains("voices") == true)
        #expect(result.diagnostics.first?.location == "Chord/Spanner[Slur]")
    }

    // MARK: - Inline shapes

    /// `<voices>` is the field a cross-voice slur uses, and losing it moves
    /// the slur's end — the encoder can only place the `<prev>` inside the
    /// begin side's own voice. So it warns, naming the tag.
    @Test("a cross-voice slur's <voices> is announced")
    func crossVoiceLocationWarns() throws {
        let decoded = try decodeChord("""
        <Chord>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <Slur>
              </Slur>
            <next>
              <location>
                <voices>-1</voices>
                <fractions>1/4</fractions>
                </location>
              </next>
            </Spanner>
          <Note>
            <pitch>72</pitch>
            <tpc>14</tpc>
            </Note>
          </Chord>
        """)
        // The slur is still decoded — only the voice hop is lost.
        #expect(decoded.chord.spanners.count == 1)
        #expect(decoded.chord.spanners.first?.nextFractionsOffset
            == Fraction(numerator: 1, denominator: 4))
        #expect(decoded.diagnostics.map(\.code) == ["mscx.slur.locationDropped"])
        #expect(decoded.diagnostics.first?.message.contains("voices") == true)
        #expect(decoded.diagnostics.first?.location == "Chord/Spanner[Slur]")
    }

    /// Every unread `<location>` field lands in ONE diagnostic per slur, tags
    /// sorted and deduped — the same shape `mscx.slur.propertiesDropped` uses.
    /// `<measures>` / `<fractions>` are read by `Spanner.decode` and must not
    /// appear.
    @Test("unread <location> fields are announced in one sorted diagnostic")
    func unreadLocationFieldsWarnOnce() throws {
        let decoded = try decodeChord("""
        <Chord>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <Slur>
              </Slur>
            <next>
              <location>
                <staves>1</staves>
                <voices>-1</voices>
                <measures>1</measures>
                <fractions>1/4</fractions>
                <grace>0</grace>
                <notes>2</notes>
                </location>
              </next>
            </Spanner>
          <Note>
            <pitch>72</pitch>
            <tpc>14</tpc>
            </Note>
          </Chord>
        """)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.slur.locationDropped"])
        let message = try #require(decoded.diagnostics.first?.message)
        #expect(message.hasSuffix("grace, notes, staves, voices"))
    }

    /// A `<location>` holding only what the model reads says nothing, and a
    /// `<prev>`-only end marker is not inspected at all — it is discarded
    /// wholesale, so its `<location>` cannot represent a loss.
    @Test("modeled-only and <prev>-side locations stay silent")
    func modeledLocationsStaySilent() throws {
        let decoded = try decodeChord("""
        <Chord>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <prev>
              <location>
                <voices>1</voices>
                <fractions>-1/4</fractions>
                </location>
              </prev>
            </Spanner>
          <Spanner type="Slur">
            <Slur>
              </Slur>
            <next>
              <location>
                <measures>1</measures>
                <fractions>1/4</fractions>
                </location>
              </next>
            </Spanner>
          <Note>
            <pitch>72</pitch>
            <tpc>14</tpc>
            </Note>
          </Chord>
        """)
        #expect(decoded.chord.spanners.count == 1)
        #expect(decoded.diagnostics.isEmpty)
    }

    // MARK: - Helpers

    private func decodeChord(
        _ xml: String,
    ) throws -> (chord: Chord, diagnostics: [ScoreDiagnostic]) {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let collector = MSCXDiagnosticCollector()
        let chord = try MSCXParserContext.$collector.withValue(collector) {
            try Chord.decode(node)
        }
        return (chord, collector.entries)
    }
}
