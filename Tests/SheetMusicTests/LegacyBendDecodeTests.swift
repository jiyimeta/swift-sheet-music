import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Decoding of the legacy MuseScore 3 `<Bend>` child of `<Note>` into
/// `Note.legacyBend`.
///
/// Both `legacybend_ms3_*` fixtures are MuseScore 3.6.2's own bend playback
/// tests (`mtest/libmscore/midi/testBends1.mscx` / `testBends2.mscx`), so
/// every count and point value below was read out of the vendored file
/// rather than assumed — see the per-test comments for the line references.
@Suite("Legacy MS3 bend decode")
struct LegacyBendDecodeTests {
    // MARK: - Fixtures

    /// `legacybend_ms3_canonical.mscx`: six whole-note bends on D4, one per
    /// measure. The first five are the canonical curve tables of
    /// `libmscore/bend.cpp` (bend, bend/release, bend/release/bend, prebend,
    /// prebend/release, `:92`, `:108`, `:126`, `:146`, `:161`); the sixth
    /// (`:178`) is a hand-drawn 13-point curve that no table produces.
    @Test("canonical curves: five table curves plus one custom 13-point curve")
    func decodesCanonicalCurves() throws {
        let bends = try legacyBends(inFixture: "legacybend_ms3_canonical")
        #expect(bends.count == 6)
        // First bend: BEND_CURVE {(0,0),(15,100),(60,100)}.
        #expect(bends[0].points == [
            LegacyBend.Point(time: 0, pitch: 0, vibrato: 0),
            LegacyBend.Point(time: 15, pitch: 100, vibrato: 0),
            LegacyBend.Point(time: 60, pitch: 100, vibrato: 0),
        ])
        // Second: BEND_RELEASE_CURVE.
        #expect(bends[1].points == [
            LegacyBend.Point(time: 0, pitch: 0, vibrato: 0),
            LegacyBend.Point(time: 10, pitch: 100, vibrato: 0),
            LegacyBend.Point(time: 20, pitch: 100, vibrato: 0),
            LegacyBend.Point(time: 30, pitch: 0, vibrato: 0),
            LegacyBend.Point(time: 60, pitch: 0, vibrato: 0),
        ])
        // Third: BEND_RELEASE_BEND_CURVE.
        #expect(bends[2].points.count == 7)
        #expect(bends[2].points.last == LegacyBend.Point(time: 60, pitch: 100, vibrato: 0))
        // Fourth: PREBEND_CURVE {(0,100),(60,100)} — starts bent.
        #expect(bends[3].points == [
            LegacyBend.Point(time: 0, pitch: 100, vibrato: 0),
            LegacyBend.Point(time: 60, pitch: 100, vibrato: 0),
        ])
        // Fifth: PREBEND_RELEASE_CURVE.
        #expect(bends[4].points == [
            LegacyBend.Point(time: 0, pitch: 100, vibrato: 0),
            LegacyBend.Point(time: 15, pitch: 100, vibrato: 0),
            LegacyBend.Point(time: 30, pitch: 0, vibrato: 0),
            LegacyBend.Point(time: 60, pitch: 0, vibrato: 0),
        ])
        // Sixth: the custom curve, with the only quarter-tone pitches in
        // either fixture (25 = 1/4 tone, 275 = 5 1/2 semitones).
        #expect(bends[5].points.count == 13)
        #expect(bends[5].points.map(\.pitch)
            == [0, 50, 100, 125, 25, 275, 25, 275, 25, 275, 75, 225, 100])
        // Every point in this fixture carries vibrato="0" explicitly.
        #expect(bends.allSatisfy { $0.points.allSatisfy { $0.vibrato == 0 } })
        // No `<play>` element anywhere in the fixture, so all curves sound.
        // `allSatisfy(\.play)` would be the natural spelling, but `#expect`
        // cannot expand a key path into a `rethrows` call — `bends.count` is
        // pinned above, so this says the same thing.
        #expect(bends.filter(\.play).count == 6)
        // Nothing in the fixture restyles a bend.
        #expect(bends.allSatisfy { $0.lineWidth == nil && $0.fontFace == nil })
        #expect(bends.allSatisfy { $0.fontSize == nil && $0.fontStyle == nil })
    }

    /// `legacybend_ms3_play_and_beams.mscx`: seven bends spread over beamed
    /// eighths and whole notes, two of them silenced with `<play>0</play>`
    /// (`:204`, `:313`).
    @Test("play flag: two of seven bends are silenced")
    func decodesPlayFlag() throws {
        let bends = try legacyBends(inFixture: "legacybend_ms3_play_and_beams")
        #expect(bends.count == 7)
        #expect(bends.filter { !$0.play }.count == 2)
    }

    // MARK: - Properties no vendored fixture exercises

    /// `<lineWidth>`, `<fontFace>`, `<fontSize>` and `<fontStyle>` are only
    /// written when the user restyled the bend, so neither fixture has them.
    @Test("styled overrides are read verbatim")
    func decodesStyledProperties() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>62</pitch>
          <tpc>16</tpc>
          <Bend>
            <point time="0" pitch="0" vibrato="0"/>
            <point time="60" pitch="100" vibrato="3"/>
            <lineWidth>0.2</lineWidth>
            <fontFace>Times New Roman</fontFace>
            <fontSize>10.5</fontSize>
            <fontStyle>1</fontStyle>
          </Bend>
        </Note>
        """)
        let bend = try #require(decoded.note.legacyBend)
        #expect(bend.points == [
            LegacyBend.Point(time: 0, pitch: 0, vibrato: 0),
            LegacyBend.Point(time: 60, pitch: 100, vibrato: 3),
        ])
        #expect(bend.lineWidth == 0.2)
        #expect(bend.fontFace == "Times New Roman")
        #expect(bend.fontSize == 10.5)
        #expect(bend.fontStyle == 1)
        #expect(decoded.diagnostics.isEmpty)
    }

    /// `vibrato` is the one optional point attribute — MuseScore always
    /// writes it, but an absent one must land on 0 rather than drop the point.
    @Test("an absent vibrato attribute defaults to 0")
    func absentVibratoDefaultsToZero() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>62</pitch>
          <tpc>16</tpc>
          <Bend>
            <point time="0" pitch="0"/>
            <point time="60" pitch="100"/>
          </Bend>
        </Note>
        """)
        let bend = try #require(decoded.note.legacyBend)
        #expect(bend.points == [
            LegacyBend.Point(time: 0, pitch: 0, vibrato: 0),
            LegacyBend.Point(time: 60, pitch: 100, vibrato: 0),
        ])
        #expect(bend.play)
        #expect(decoded.diagnostics.isEmpty)
    }

    // MARK: - Diagnostics

    /// Half a curve would lay out and play as a different bend, so a point
    /// missing `time` or `pitch` drops the whole element.
    @Test("a point missing time or pitch drops the bend and warns")
    func malformedPointWarns() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>62</pitch>
          <tpc>16</tpc>
          <Bend>
            <point time="0" pitch="0" vibrato="0"/>
            <point time="60" vibrato="0"/>
          </Bend>
        </Note>
        """)
        #expect(decoded.note.legacyBend == nil)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.bend.malformedPoint"])
    }

    /// Item properties MuseScore writes on any element (`offset`, `visible`,
    /// `color`, …) carry real user intent, so dropping them is announced
    /// rather than silent. The curve itself still decodes.
    @Test("unmodeled <Bend> children are announced in one diagnostic")
    func unknownChildrenWarn() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>62</pitch>
          <tpc>16</tpc>
          <Bend>
            <point time="0" pitch="0"/>
            <point time="60" pitch="100"/>
            <offset x="1" y="2"/>
            <visible>0</visible>
          </Bend>
        </Note>
        """)
        #expect(decoded.note.legacyBend?.points.count == 2)
        #expect(decoded.diagnostics.map(\.code) == ["mscx.bend.propertiesDropped"])
        #expect(decoded.diagnostics.first?.message
            == "<Bend> children not modeled and dropped: offset, visible")
    }

    /// `<eid>` is MuseScore 4.6's regenerated internal element id. No decoder
    /// in this package models it, it carries no user data, and announcing it
    /// would fire on every element of every 4.6 score — so it stays silent.
    @Test("<eid> is elided without a diagnostic")
    func eidIsSilentlyElided() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>62</pitch>
          <tpc>16</tpc>
          <Bend>
            <eid>4123456789012345</eid>
            <point time="0" pitch="0"/>
            <point time="60" pitch="100"/>
          </Bend>
        </Note>
        """)
        #expect(decoded.note.legacyBend?.points.count == 2)
        #expect(decoded.diagnostics.isEmpty)
    }

    /// `Note.legacyBend` holds one curve, so a second `<Bend>` on the same
    /// note cannot be kept. MuseScore never writes one — announcing it means
    /// a hand-edited or foreign file says so instead of losing a curve.
    @Test("a second <Bend> child is dropped with a warning")
    func duplicateBendWarns() throws {
        let decoded = try decodeNote("""
        <Note>
          <pitch>62</pitch>
          <tpc>16</tpc>
          <Bend>
            <point time="0" pitch="0"/>
            <point time="60" pitch="100"/>
          </Bend>
          <Bend>
            <point time="0" pitch="100"/>
            <point time="60" pitch="0"/>
          </Bend>
        </Note>
        """)
        // The first curve — rising — is the one kept.
        #expect(decoded.note.legacyBend?.points == [
            LegacyBend.Point(time: 0, pitch: 0, vibrato: 0),
            LegacyBend.Point(time: 60, pitch: 100, vibrato: 0),
        ])
        #expect(decoded.diagnostics.map(\.code) == ["mscx.bend.duplicateDropped"])
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

    private func legacyBends(inFixture fixture: String) throws -> [LegacyBend] {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData(fixture))
        return allNotes(in: score).compactMap(\.legacyBend)
    }

    /// Walk every staff / measure / voice / chord / note in document order.
    /// Neither fixture uses grace notes, but the walk mirrors
    /// `GuitarBendDecodeTests` so the two read the same.
    private func allNotes(in score: Score) -> [Note] {
        score.allStaves.flatMap { _, staff in
            staff.measures.flatMap { measure in
                measure.voices.flatMap { voice in
                    voice.elements.flatMap { element -> [Note] in
                        guard case let .chord(chord) = element else { return [] }
                        return chord.graceNotesBefore.flatMap(\.notes)
                            + chord.notes
                            + chord.graceNotesAfter.flatMap(\.notes)
                    }
                }
            }
        }
    }
}
