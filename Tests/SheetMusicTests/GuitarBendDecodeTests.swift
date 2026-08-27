import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Decoding of `<Spanner type="GuitarBend">` into `Note.guitarBend` /
/// `Note.guitarBendBack`.
///
/// The six `guitarbend_*` fixtures are MuseScore's own playback-test scores
/// (`src/engraving/tests/midi/midirenderer_bend_data/`), so every count below
/// was read out of the vendored file rather than assumed — see the per-test
/// comments for the line references.
@Suite("GuitarBend decode")
struct GuitarBendDecodeTests {
    // MARK: - Fixtures

    /// `guitarbend_simple.mscx`: three plain bends, each starting on one note
    /// and ending on the next (`:150`, `:204`, `:252` carry the payload;
    /// `:178`, `:232`, `:280` are the `<prev>`-only end sides).
    @Test("simple: three plain bends, payload only on the begin side")
    func simpleBends() throws {
        let notes = try notes(inFixture: "guitarbend_simple")
        let bends = notes.compactMap(\.guitarBend)
        #expect(bends.count == 3)
        #expect(bends.allSatisfy { $0.type == .bend })
        // Fixture order: (0, 1), (0.25, 0.75), (0, 1).
        #expect(bends.map(\.startTimeFactor) == [0, 0.25, 0])
        #expect(bends.map(\.endTimeFactor) == [1, 0.75, 1])
        // None of the fixtures exercise these, so they must stay at default.
        #expect(bends.allSatisfy { $0.targetTimeFactor == nil })
        #expect(bends.allSatisfy { $0.showHoldLine == .auto })
        #expect(bends.allSatisfy { !$0.hasHoldLine })
        #expect(notes.filter(\.guitarBendBack).count == 3)
        // Begin and end land on different notes here — unlike the slight bend.
        #expect(notes.allSatisfy { $0.guitarBend == nil || !$0.guitarBendBack })
    }

    /// `guitarbend_slightbend.mscx`: the begin and end spanners sit on the
    /// *same* `<Note>` (`:144` + `:157`, `:176` + `:189`, `:208` + `:221`),
    /// which is what distinguishes a slight bend from every other type.
    @Test("slight bend: begin and end spanner on the same note")
    func slightBends() throws {
        let notes = try notes(inFixture: "guitarbend_slightbend")
        let bent = notes.filter { $0.guitarBend != nil }
        #expect(bent.count == 3)
        #expect(bent.allSatisfy { $0.guitarBend?.type == .slightBend })
        // `allSatisfy(\.guitarBendBack)` would be the natural spelling, but
        // `#expect` cannot expand a key path into a `rethrows` call, and the
        // closure form trips SwiftFormat's `preferKeyPath`. `bent.count` is
        // pinned above, so this says the same thing.
        #expect(bent.filter(\.guitarBendBack).count == 3)
        #expect(notes.filter(\.guitarBendBack).count == 3)
        #expect(bent.compactMap(\.guitarBend).map(\.startTimeFactor) == [0, 0.25, 0])
    }

    /// `guitarbend_prebend.mscx`: five bends — three `PRE_BEND` on
    /// `<appoggiatura/>` grace chords (`:158`, `:215`, `:309`) and two plain
    /// bends (`:239`, `:372`).
    @Test("prebend: three pre-bends alongside two plain bends")
    func preBends() throws {
        let notes = try notes(inFixture: "guitarbend_prebend")
        let bends = notes.compactMap(\.guitarBend)
        #expect(bends.count == 5)
        #expect(bends.filter { $0.type == .preBend }.count == 3)
        #expect(bends.filter { $0.type == .bend }.count == 2)
        #expect(notes.filter(\.guitarBendBack).count == 5)
    }

    /// `guitarbend_gracebend.mscx`: every bend hangs off the grace note, not
    /// the principal (`:145`, `:199`, `:268` are `<appoggiatura/>` chords).
    @Test("grace bend: the grace note carries the bend")
    func graceBends() throws {
        let score = try parse("guitarbend_gracebend")
        var onGraceNotes: [GuitarBend] = []
        for chord in chords(in: score) {
            for grace in chord.graceNotesBefore {
                onGraceNotes.append(contentsOf: grace.notes.compactMap(\.guitarBend))
            }
        }
        #expect(onGraceNotes.count == 3)
        #expect(onGraceNotes.allSatisfy { $0.type == .graceNoteBend })
        // Nothing outside the grace chords carries a bend.
        #expect(allNotes(in: score).compactMap(\.guitarBend).count == 3)
        #expect(allNotes(in: score).filter(\.guitarBendBack).count == 3)
    }

    /// `guitarbend_release_twice.mscx`: two `GRACE_NOTE_BEND` on
    /// `<grace8after/>` chords (`:98`, `:177`) and two plain bends
    /// (`:129`, `:208`), with non-default time factors on the second pair.
    @Test("release twice: mixed types and non-default time factors")
    func releaseTwice() throws {
        let notes = try notes(inFixture: "guitarbend_release_twice")
        let bends = notes.compactMap(\.guitarBend)
        #expect(bends.count == 4)
        #expect(bends.filter { $0.type == .graceNoteBend }.count == 2)
        #expect(bends.filter { $0.type == .bend }.count == 2)
        #expect(bends.contains { $0.startTimeFactor == 0 && $0.endTimeFactor == 0.5 })
        #expect(bends.contains { $0.startTimeFactor == 0.25 && $0.endTimeFactor == 0.75 })
        #expect(notes.filter(\.guitarBendBack).count == 4)
    }

    /// `guitarbend_tied.mscx` mixes `<Spanner type="Tie">` and
    /// `<Spanner type="GuitarBend">` inside the same `<Note>`, so it is the
    /// regression guard that extending the spanner walk did not disturb ties.
    @Test("tied: guitar bends and ties coexist inside one <Note>")
    func tiedBends() throws {
        let notes = try notes(inFixture: "guitarbend_tied")
        let bends = notes.compactMap(\.guitarBend)
        #expect(bends.count == 2)
        #expect(bends.allSatisfy { $0.type == .bend })
        #expect(notes.filter(\.guitarBendBack).count == 2)
        // `:173` / `:229` are `<next>`, `:196` / `:252` are `<prev>`.
        #expect(notes.filter { $0.tieForward != nil }.count == 2)
        #expect(notes.filter { $0.tieBack != nil }.count == 2)
    }

    // MARK: - Properties no vendored fixture exercises

    @Test("optional payload: target time factor, hold line, show-hold-line")
    func optionalPayload() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>60</pitch>
          <tpc>14</tpc>
          <Spanner type="GuitarBend">
            <GuitarBend>
              <guitarBendType>0</guitarBendType>
              <bendStartTimeFactor>0.2</bendStartTimeFactor>
              <bendEndTimeFactor>0.8</bendEndTimeFactor>
              <bendTargetTimeFactor>0.5</bendTargetTimeFactor>
              <bendShowHoldLine>1</bendShowHoldLine>
              <GuitarBendHold>
                <eid>1</eid>
              </GuitarBendHold>
            </GuitarBend>
            <next><location><fractions>1/4</fractions></location></next>
          </Spanner>
        </Note>
        """)
        let bend = try #require(decoded.note.guitarBend)
        #expect(bend.type == .bend)
        #expect(bend.startTimeFactor == 0.2)
        #expect(bend.endTimeFactor == 0.8)
        #expect(bend.targetTimeFactor == 0.5)
        #expect(bend.showHoldLine == .show)
        #expect(bend.hasHoldLine)
        #expect(decoded.diagnostics.isEmpty)
    }

    /// MuseScore's writer omits `<bendStartTimeFactor>` / `<bendEndTimeFactor>`
    /// only in files older than the property; the decoder must still land on
    /// the C++ defaults (0 and 1) rather than on zero for both.
    @Test("absent time factors fall back to the MuseScore defaults 0 and 1")
    func absentTimeFactorsUseDefaults() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>60</pitch>
          <tpc>14</tpc>
          <Spanner type="GuitarBend">
            <GuitarBend><guitarBendType>2</guitarBendType></GuitarBend>
            <next><location><fractions>1/4</fractions></location></next>
          </Spanner>
        </Note>
        """)
        let bend = try #require(decoded.note.guitarBend)
        #expect(bend.type == .graceNoteBend)
        #expect(bend.startTimeFactor == 0)
        #expect(bend.endTimeFactor == 1)
        #expect(bend.targetTimeFactor == nil)
        #expect(bend.showHoldLine == .auto)
        #expect(!bend.hasHoldLine)
    }

    /// A `<prev>`-only spanner is the end side and carries no `<GuitarBend>`
    /// block, so it must set the flag without inventing a payload.
    @Test("a <prev>-only spanner sets guitarBendBack and no payload")
    func prevOnlySpanner() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>60</pitch>
          <tpc>14</tpc>
          <Spanner type="GuitarBend">
            <prev><location><fractions>-1/4</fractions></location></prev>
          </Spanner>
        </Note>
        """)
        #expect(decoded.note.guitarBend == nil)
        #expect(decoded.note.guitarBendBack)
        #expect(decoded.diagnostics.isEmpty)
    }

    // MARK: - Diagnostics

    @Test("an unknown <guitarBendType> drops the bend and warns")
    func unknownTypeWarns() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>60</pitch>
          <tpc>14</tpc>
          <Spanner type="GuitarBend">
            <GuitarBend><guitarBendType>99</guitarBendType></GuitarBend>
            <next><location><fractions>1/4</fractions></location></next>
          </Spanner>
        </Note>
        """)
        #expect(decoded.note.guitarBend == nil)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.guitarBend.unknownType"])
    }

    /// A begin side with no `<GuitarBend>` block is malformed — MuseScore's
    /// writer always emits the payload on the `<next>` side. Dropping it
    /// silently would strand the end note's `guitarBendBack`.
    @Test("a <next> side with no payload block warns")
    func missingPayloadWarns() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>60</pitch>
          <tpc>14</tpc>
          <Spanner type="GuitarBend">
            <next><location><fractions>1/4</fractions></location></next>
          </Spanner>
        </Note>
        """)
        #expect(decoded.note.guitarBend == nil)
        #expect(!decoded.note.guitarBendBack)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.guitarBend.missingPayload"])
    }

    /// `<direction>` — which side of the note the bend arc is drawn on — is
    /// not modeled. MuseScore writes the tag only when the user flipped it off
    /// `DirectionV::AUTO`, so its presence is always real user intent.
    @Test("a user-flipped <direction> is dropped with a warning")
    func directionDroppedWarns() throws {
        let decoded = try decodePayload("<direction>down</direction>")
        #expect(decoded.note.guitarBend?.type == .bend)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.guitarBend.directionDropped"])
    }

    /// Payload children that lose nothing and so must never warn:
    ///
    /// - `<direction>auto</direction>` — MuseScore never serializes
    ///   `DirectionV::AUTO`, but a hand-written file may spell it out.
    /// - `<eid>` — see `LegacyBendDecodeTests.eidIsSilentlyElided`.
    /// - `<anchor>` — `SLine`'s spanner anchor, written unconditionally for
    ///   every guitar bend (`rw/write/twrite.cpp:1606`, reached from
    ///   `TWrite::write(const GuitarBend*, …)`'s trailing
    ///   `writeProperties(SLine*, …)` at `:1568`) and re-emitted verbatim by
    ///   this package's encoder. The `<eid>` + `<anchor>` pair is exactly what
    ///   every vendored fixture carries.
    @Test("children that lose nothing produce no diagnostic", arguments: [
        "<direction>auto</direction>",
        "<eid>4123456789012345</eid>",
        "<anchor>3</anchor>",
        "<eid>11974368821379</eid><anchor>3</anchor>",
    ])
    func silentPayloadChildren(_ payload: String) throws {
        let decoded = try decodePayload(payload)
        #expect(decoded.note.guitarBend?.type == .bend)
        #expect(decoded.diagnostics.map(\.code) == [])
    }

    /// The inline tests install a collector by hand; the fixture tests go
    /// through `MSCXParser.parse`, which *discards* diagnostics — so a green
    /// fixture suite was never evidence that the vendored scores decode
    /// cleanly. This is that evidence. Every one of these carries `<eid>` and
    /// `<anchor>` on each payload, and none may produce a diagnostic.
    @Test("the vendored fixtures decode without any diagnostic", arguments: [
        "guitarbend_simple", "guitarbend_prebend", "guitarbend_gracebend",
        "guitarbend_release_twice", "guitarbend_slightbend", "guitarbend_tied",
    ])
    func fixturesDecodeWithoutDiagnostics(_ fixture: String) throws {
        let result = try MSCXParser.parseWithDiagnostics(
            MSCXFixtureLoader.mscxData(fixture),
        )
        #expect(result.diagnostics.map(\.code) == [])
    }

    /// Item properties (`offset`, `visible`, …) sit alongside the bend's own
    /// payload and are not modeled; the bend still decodes.
    @Test("unmodeled <GuitarBend> children are announced in one diagnostic")
    func unknownPayloadChildrenWarn() throws {
        let decoded = try decodePayload(
            "<offset x=\"1\" y=\"2\"/><visible>0</visible>",
        )
        #expect(decoded.note.guitarBend?.type == .bend)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.guitarBend.propertiesDropped"])
        #expect(decoded.diagnostics.first?.message
            == "<GuitarBend> children not modeled and dropped: offset, visible")
    }

    /// The whammy-bar types carry four extra properties this model does not
    /// hold. The bend itself still decodes; only the extras are announced.
    @Test("dive-only properties are dropped with a warning")
    func divePropertiesWarn() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>60</pitch>
          <tpc>14</tpc>
          <Spanner type="GuitarBend">
            <GuitarBend>
              <guitarBendType>4</guitarBendType>
              <guitarDiveTabPos>1</guitarDiveTabPos>
              <guitarDiveIsSlack>1</guitarDiveIsSlack>
            </GuitarBend>
            <next><location><fractions>1/4</fractions></location></next>
          </Spanner>
        </Note>
        """)
        #expect(decoded.note.guitarBend?.type == .dive)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.guitarBend.divePropertiesDropped"])
    }

    /// A legacy MuseScore 3 `<Bend>` is a curve on one note, not a spanner
    /// pair, so it must land in `legacyBend` and leave both guitar-bend
    /// fields alone — see `LegacyBendDecodeTests` for the curve itself.
    @Test("a legacy MuseScore 3 <Bend> child is not a guitar bend")
    func legacyBendIsNotAGuitarBend() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>60</pitch>
          <tpc>14</tpc>
          <Bend>
            <point time="0" pitch="0"/>
            <point time="15" pitch="100"/>
          </Bend>
        </Note>
        """)
        #expect(decoded.note.guitarBend == nil)
        #expect(!decoded.note.guitarBendBack)
        #expect(decoded.note.legacyBend?.points.count == 2)
        #expect(decoded.diagnostics.isEmpty)
    }

    // MARK: - Helpers

    private func decodeNote(
        _ xml: String,
    ) throws -> (note: Note, diagnostics: [ScoreDiagnostic]) {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let collector = MSCXDiagnosticCollector()
        let note = try MSCXParserContext.$collector.withValue(collector) {
            try Note.decode(node)
        }
        return (note, collector.entries)
    }

    /// Decode a plain `<Note>` carrying a begin-side `GuitarBend` spanner
    /// whose payload holds `<guitarBendType>0</guitarBendType>` plus
    /// `extraChildren` — the boilerplate every payload-level diagnostic test
    /// would otherwise repeat.
    private func decodePayload(
        _ extraChildren: String,
    ) throws -> (note: Note, diagnostics: [ScoreDiagnostic]) {
        try decodeNote("""
        <Note>
          <pitch>60</pitch>
          <tpc>14</tpc>
          <Spanner type="GuitarBend">
            <GuitarBend><guitarBendType>0</guitarBendType>\(extraChildren)</GuitarBend>
            <next><location><fractions>1/4</fractions></location></next>
          </Spanner>
        </Note>
        """)
    }

    private func parse(_ fixture: String) throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData(fixture))
    }

    private func notes(inFixture fixture: String) throws -> [Note] {
        try allNotes(in: parse(fixture))
    }

    private func chords(in score: Score) -> [Chord] {
        score.allStaves.flatMap { _, staff in
            staff.measures.flatMap { measure in
                measure.voices.flatMap { voice in
                    voice.elements.compactMap { element in
                        guard case let .chord(chord) = element else { return nil }
                        return chord
                    }
                }
            }
        }
    }

    /// Grace notes carry bends in four of the six fixtures, so they have to be
    /// part of the walk — `graceNotesBefore` for the appoggiaturas and
    /// `graceNotesAfter` for `guitarbend_release_twice`'s `<grace8after/>`.
    private func allNotes(in score: Score) -> [Note] {
        chords(in: score).flatMap { chord in
            chord.graceNotesBefore.flatMap(\.notes)
                + chord.notes
                + chord.graceNotesAfter.flatMap(\.notes)
        }
    }
}
