import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Decoding of chord-anchored `<Spanner type="Slur">` into `Chord.spanners`.
///
/// MuseScore writes a slur as a *pair* of `<Spanner>` children of the
/// chord/rest it starts and ends on: the begin side carries the `<Slur>`
/// payload plus a `<next><location>` offset, the end side is a bare
/// `<prev><location>` marker. Only begin sides become `Chord.spanners`
/// entries — the `<prev>` side holds no model state.
///
/// Both fixtures are MuseScore's own test data, vendored verbatim, and every
/// count and offset asserted below was read out of the vendored file rather
/// than assumed — the per-fixture doc comments carry the line references.
@Suite("Chord-anchored slur decode")
struct SlurDecodeTests {
    // MARK: - Fixture gates

    /// `MSCXParser.parse` *discards* diagnostics, so the decode assertions
    /// below are no evidence that the vendored scores decode cleanly. This is
    /// that evidence — and the gate that keeps a future decoder change from
    /// quietly starting to drop data these fixtures carry.
    ///
    /// It is also what pins the `<Slur>` allowlist honest: every payload child
    /// these scores carry is either modeled or allowlisted with a citing
    /// comment, so a real dropped property shows up as a failure here.
    /// `slur_ms4_glissando_legato` is MuseScore's own file;
    /// `slur_ms4_resave` is this package's byte-parity fixture, and gating it
    /// here means the encoder can never write something its own decoder would
    /// have to warn about.
    ///
    /// `slur_ms3_exchangevoices` is *not* in this list — its cross-voice slur
    /// is one real, known loss, gated in `SlurLocationDiagnosticsTests`.
    @Test("the clean fixtures decode without any diagnostic", arguments: [
        "slur_ms4_glissando_legato",
        "slur_ms4_resave",
    ])
    func fixturesDecodeWithoutDiagnostics(_ fixture: String) throws {
        let result = try MSCXParser.parseWithDiagnostics(
            MSCXFixtureLoader.mscxData(fixture),
        )
        #expect(result.diagnostics.map(\.code) == [])
    }

    // MARK: - Fixture decode

    /// `slur_ms4_glissando_legato.mscx` — MuseScore 4.2's own MIDI-renderer
    /// fixture `src/engraving/tests/midi/midirenderer_data/
    /// simple_glissando_legato.mscx`. One measure, one guitar part with a
    /// standard staff (id 1) and a linked tablature staff (id 2), so every
    /// element is written twice.
    ///
    /// Four `<Spanner type="Slur">` elements = **two slurs**, one per staff:
    /// - staff 1 begin at `:137`, `<Slur>` payload `<linkedMain/>` only,
    ///   `<next><location><fractions>1/2</fractions>` (no `<measures>`);
    ///   `<prev>`-only end at `:170` with `-1/2`.
    /// - staff 2 begin at `:210`, `<Slur>` payload `<linked></linked>` only,
    ///   same `1/2`; `<prev>`-only end at `:247`.
    ///
    /// Payload-child inventory inside `<Slur>` across the whole file:
    /// `linkedMain`, `linked`. Nothing else — both are allowlisted.
    ///
    /// The file also carries `<Spanner type="Glissando">` pairs, but those are
    /// `<Note>` children, not `<Chord>` children, so the chord walk must not
    /// see them: `XMLTreeNode.all` matches direct children only.
    @Test("MS4: one slur per linked staff, half-note span")
    func decodesMS4Slurs() throws {
        let slurs = try slurs(inFixture: "slur_ms4_glissando_legato")
        #expect(slurs.count == 2)
        for slur in slurs {
            #expect(slur.kind == .slur)
            #expect(slur.rawType == "Slur")
            #expect(slur.nextMeasuresOffset == 0)
            #expect(slur.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
        }
    }

    /// `slur_ms3_exchangevoices.mscx` — MuseScore 3.6.2's
    /// `mtest/libmscore/exchangevoices/exchangevoices-slurs.mscx`, vendored as
    /// the MS3 half. Three measures, one piano staff, two voices in measure 2.
    ///
    /// Six `<Spanner type="Slur">` elements = **three slurs**, every `<Slur>`
    /// payload empty (`<Slur></Slur>`) — MuseScore 3 writes nothing inside a
    /// slur that the user never restyled or dragged:
    /// - m1 v1, first eighth (pitch 60): `<next>` `<fractions>7/8</fractions>`,
    ///   ending on the last eighth of the same measure (`-7/8` on the end).
    /// - m2 v1, the half note (pitch 74): `<next>` `<measures>1</measures>`
    ///   *and* `<fractions>-1/2</fractions>` — the only fixture slur with a
    ///   measure component.
    /// - m2 v2, first quarter (pitch 65): `<next>` `<voices>-1</voices>` and
    ///   `<fractions>1/4</fractions>` — a cross-voice slur. `<voices>` is not
    ///   read by `Spanner.decode` (it is a voice hop, not a tick offset), so
    ///   only the `1/4` lands on the model.
    ///
    /// The end sides sit on the chords at `-7/8`, `measures -1 / 1/2`, and
    /// `voices 1 / -1/4`, and are consumed silently.
    @Test("MS3: three slurs, one of them crossing a barline and one a voice")
    func decodesMS3Slurs() throws {
        let slurs = try slurs(inFixture: "slur_ms3_exchangevoices")
        try #require(slurs.count == 3)
        #expect(slurs.allSatisfy { $0.kind == .slur })
        // Document order across staff / measure / voice.
        #expect(slurs[0].nextMeasuresOffset == 0)
        #expect(slurs[0].nextFractionsOffset == Fraction(numerator: 7, denominator: 8))
        #expect(slurs[1].nextMeasuresOffset == 1)
        #expect(slurs[1].nextFractionsOffset == Fraction(numerator: -1, denominator: 2))
        #expect(slurs[2].nextMeasuresOffset == 0)
        #expect(slurs[2].nextFractionsOffset == Fraction(numerator: 1, denominator: 4))
    }

    // MARK: - Begin / end / malformed shapes

    /// A `<prev>`-only Slur is the end marker of a pair whose begin side lives
    /// on an earlier chord. It carries no model state — MuseScore recomputes
    /// it from the begin side's `<next>` on write — so it is consumed in
    /// silence rather than announced as dropped data.
    @Test("a <prev>-only slur is consumed silently")
    func prevOnlySlurIsSilent() throws {
        let decoded = try decodeChord("""
        <Chord>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <prev>
              <location>
                <fractions>-1/2</fractions>
                </location>
              </prev>
            </Spanner>
          <Note>
            <pitch>72</pitch>
            <tpc>14</tpc>
            </Note>
          </Chord>
        """)
        #expect(decoded.chord.spanners.isEmpty)
        #expect(decoded.diagnostics.isEmpty)
    }

    /// Neither `<next>` nor `<prev>` is a shape MuseScore never writes — the
    /// element is neither a begin side that can be placed nor an end marker
    /// that can be discarded, so it is dropped with a warning rather than
    /// silently swallowed.
    @Test("a slur with neither <next> nor <prev> warns")
    func slurWithoutEitherLocationWarns() throws {
        let decoded = try decodeChord("""
        <Chord>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <Slur>
              </Slur>
            </Spanner>
          <Note>
            <pitch>72</pitch>
            <tpc>14</tpc>
            </Note>
          </Chord>
        """)
        #expect(decoded.chord.spanners.isEmpty)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.chord.spannerDropped"])
        #expect(decoded.diagnostics.first?.message.contains("missing <next>/<prev>") == true)
    }

    /// Only slurs are modeled at chord level. Any other chord-anchored spanner
    /// type is real data this decoder throws away, announced once, naming the
    /// type so the report says which feature is missing.
    @Test("a non-Slur chord-level spanner warns once, naming the type")
    func nonSlurChordSpannerWarns() throws {
        let decoded = try decodeChord("""
        <Chord>
          <durationType>quarter</durationType>
          <Spanner type="HairPin">
            <HairPin>
              <subtype>0</subtype>
              </HairPin>
            <next>
              <location>
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
        #expect(decoded.chord.spanners.isEmpty)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.chord.spannerDropped"])
        #expect(decoded.diagnostics.first?.message.contains("HairPin") == true)
    }

    // MARK: - Dropped `<Slur>` properties

    /// `<up>` (the user-forced arc side) and `<lineType>` (solid / dotted /
    /// dashed) are real user intent this model does not hold. They land in one
    /// diagnostic per slur, tags sorted and deduped.
    @Test("unmodeled <Slur> children are announced in one diagnostic")
    func unknownSlurChildrenWarn() throws {
        let decoded = try decodeChord("""
        <Chord>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <Slur>
              <up>down</up>
              <lineType>2</lineType>
              </Slur>
            <next>
              <location>
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
        // The slur itself still decodes — only its styling is lost.
        #expect(decoded.chord.spanners.count == 1)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.slur.propertiesDropped"])
        #expect(decoded.diagnostics.first?.message
            == "<Slur> children not modeled and dropped: lineType, up")
    }

    /// `<eid>` is MuseScore 4.6's regenerated element id, `<linkedMain>` /
    /// `<linked>` are the part-linking bookkeeping every score with parts
    /// carries. None hold user data, so none warn — see the allowlist comments
    /// in `MSCXDecoder+Chord.swift`.
    @Test("the allowlisted bookkeeping children stay silent")
    func allowlistedSlurChildrenAreSilent() throws {
        let decoded = try decodeChord("""
        <Chord>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <Slur>
              <eid>4123456789012345</eid>
              <linkedMain/>
              </Slur>
            <next>
              <location>
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

    /// `placement`, `visible` and `beginText` are read by `Spanner.decode` off
    /// the payload child, so they are modeled, not dropped — a slur carrying
    /// them must not warn.
    @Test("children Spanner.decode reads do not count as dropped")
    func modeledSlurChildrenAreSilent() throws {
        let decoded = try decodeChord("""
        <Chord>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <Slur>
              <placement>above</placement>
              <visible>0</visible>
              </Slur>
            <next>
              <location>
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
        let slur = try #require(decoded.chord.spanners.first)
        #expect(slur.placement == .above)
        #expect(slur.visible == false)
        #expect(decoded.diagnostics.isEmpty)
    }

    // MARK: - Rests

    /// A slur may start or end on a rest — MuseScore anchors spanners to any
    /// `ChordRest`. Rests decode through `MSCXRestDecoder` into note-less
    /// `Chord`s, which must share the same helper rather than drop the slur.
    @Test("a rest carries chord-anchored slurs too")
    func restDecodesSlurs() throws {
        let decoded = try decodeRest("""
        <Rest>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <Slur>
              </Slur>
            <next>
              <location>
                <fractions>1/4</fractions>
                </location>
              </next>
            </Spanner>
          </Rest>
        """)
        #expect(decoded.rest.notes.isEmpty)
        #expect(decoded.rest.spanners.count == 1)
        #expect(decoded.rest.spanners.first?.kind == .slur)
        #expect(decoded.rest.spanners.first?.nextFractionsOffset == Fraction(numerator: 1, denominator: 4))
        #expect(decoded.diagnostics.isEmpty)
    }

    /// The rest path shares the chord helper, so it reports the same losses.
    @Test("a rest reports dropped slur properties too")
    func restWarnsOnDroppedProperties() throws {
        let decoded = try decodeRest("""
        <Rest>
          <durationType>quarter</durationType>
          <Spanner type="Slur">
            <Slur>
              <up>up</up>
              </Slur>
            <next>
              <location>
                <fractions>1/4</fractions>
                </location>
              </next>
            </Spanner>
          </Rest>
        """)
        #expect(decoded.rest.spanners.count == 1)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.slur.propertiesDropped"])
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

    private func decodeRest(
        _ xml: String,
    ) throws -> (rest: Chord, diagnostics: [ScoreDiagnostic]) {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let collector = MSCXDiagnosticCollector()
        let rest = try MSCXParserContext.$collector.withValue(collector) {
            try MSCXRestDecoder.decode(node)
        }
        return (rest, collector.entries)
    }

    /// Every chord-anchored spanner in the score, in staff / measure / voice /
    /// element document order. Rests are note-less `Chord`s, so this walk
    /// covers them without a separate case.
    private func slurs(inFixture fixture: String) throws -> [Spanner] {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData(fixture))
        return score.allStaves.flatMap { _, staff in
            staff.measures.flatMap { measure in
                measure.voices.flatMap { voice in
                    voice.elements.flatMap { element -> [Spanner] in
                        guard case let .chord(chord) = element else { return [] }
                        return chord.spanners
                    }
                }
            }
        }
    }
}
