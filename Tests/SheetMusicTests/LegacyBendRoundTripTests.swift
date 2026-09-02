import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Encoding of the legacy MuseScore 3 `<Bend>` child of `<Note>` — the
/// mirror of `LegacyBendDecodeTests`.
@Suite("Legacy MS3 bend round-trip")
struct LegacyBendRoundTripTests {
    /// `legacybend_ms4_resave.mscx` models what MuseScore 4 writes when it
    /// re-saves an MS3 score that carries a bend: a 4.x header with the
    /// unchanged `<Bend>` shape. It is written in *this* package's writer
    /// dialect (2-space indent, attributes in sorted key order — see
    /// `XMLTreeSerializer`, whose header states that byte parity with
    /// MuseScore Studio's own writer is a non-goal), so the file is a
    /// golden fixed point: decode → encode must reproduce it byte for byte.
    ///
    /// What the fixture pins that no model-level check can is the *slot*.
    /// Its `<Bend>` sits after `</Accidental>`, before
    /// `<Spanner type="Tie">` and before `<pitch>` — MuseScore 4's own
    /// position for `el()` items, written immediately after the accidental
    /// (`TWrite::write(const Note*, …)`, `rw/write/twrite.cpp:2328-2336`).
    /// Moving the emission anywhere else in `Note.encode` fails this test.
    @Test("the MS4-era fixture survives decode → encode byte-identically")
    func ms4FixtureIsByteStable() throws {
        let data = try MSCXFixtureLoader.mscxData("legacybend_ms4_resave")
        let score = try MSCXParser.parse(data)
        let encoded = try MSCXEncoder.encode(score)
        let written = try #require(String(bytes: encoded, encoding: .utf8))
        let onDisk = try #require(String(bytes: data, encoding: .utf8))
        #expect(written == onDisk)
    }

    /// MS3-native fixture: model-level round-trip stability (second pass
    /// equals first). Whole-file v3 byte parity is deliberately not a gate —
    /// the encoder normalizes unrelated MS3-era fields, exactly as
    /// `GuitarBendRoundTripTests` documents for its own fixtures.
    @Test("the MS3 fixture reaches a fixed point with all six bends intact")
    func ms3FixtureModelRoundTrips() throws {
        let score = try MSCXParser.parse(
            MSCXFixtureLoader.mscxData("legacybend_ms3_canonical"),
        )
        let encoded = try MSCXEncoder.encode(score)
        let reDecoded = try MSCXParser.parse(encoded)
        let secondPass = try MSCXEncoder.encode(reDecoded)
        #expect(encoded == secondPass)
        // Bend fields survive the trip: five canonical curves plus the
        // hand-drawn 13-point one (`LegacyBendDecodeTests`).
        #expect(legacyBends(in: reDecoded).count == 6)
        #expect(legacyBends(in: reDecoded) == legacyBends(in: score))
    }

    /// The `<play>0</play>` flag and the styled properties write back
    /// exactly, in the writer's field order: points, styled properties,
    /// then `<play>`.
    @Test("play flag and styled properties write back in the writer's order")
    func playFlagAndStyledPropsRoundTrip() throws {
        var note = Note(pitch: 62, tpc: 16)
        note.legacyBend = LegacyBend(
            points: [
                LegacyBend.Point(time: 0, pitch: 0),
                LegacyBend.Point(time: 60, pitch: 100, vibrato: 3),
            ],
            play: false,
            lineWidth: 0.2,
            fontFace: "Edwin",
            fontSize: 10.5,
            fontStyle: 1,
        )
        let bend = try #require(note.encode().first("Bend"))
        #expect(bend.children.map(\.name)
            == [
                "point",
                "point",
                "lineWidth",
                "fontFace",
                "fontSize",
                "fontStyle",
                "play",
            ])
        #expect(bend.first("play")?.text == "0")
        #expect(bend.first("lineWidth")?.text == "0.2")
        #expect(bend.first("fontFace")?.text == "Edwin")
        #expect(bend.first("fontSize")?.text == "10.5")
        #expect(bend.first("fontStyle")?.text == "1")
        let points = bend.all("point")
        #expect(points.count == 2)
        #expect(points[1].attributes
            == ["time": "60", "pitch": "100", "vibrato": "3"])
        // Re-decoding the element must give back the same model.
        #expect(Note.decodeLegacyBend(bend) == note.legacyBend)
    }

    /// Nothing optional is written at its default: a plain, sounding,
    /// unstyled bend is three `<point>`s and nothing else. MuseScore elides
    /// `Pid::PLAY` at `true` (`writeProperty`) and writes the four styled
    /// properties only when the user overrode them.
    @Test("defaults are elided — a plain bend is points only")
    func defaultsAreElided() throws {
        var note = Note(pitch: 62, tpc: 16)
        note.legacyBend = LegacyBend(points: [
            LegacyBend.Point(time: 0, pitch: 0),
            LegacyBend.Point(time: 15, pitch: 100),
            LegacyBend.Point(time: 60, pitch: 100),
        ])
        let bend = try #require(note.encode().first("Bend"))
        #expect(bend.children.map(\.name) == ["point", "point", "point"])
    }

    /// `<Bend>` is version-independent: MuseScore 3.6.2's `Bend::write`
    /// (`libmscore/bend.cpp:285`) and MuseScore 4's
    /// `TWrite::write(const Bend*, …)` (`rw/write/twrite.cpp:825`) emit the
    /// same element, so an MS3 export must carry it unchanged.
    @Test("the v3 export emits the same <Bend> as the v4 export")
    func bendIsIdenticalAcrossTargetVersions() {
        var note = Note(pitch: 62, tpc: 16)
        note.legacyBend = LegacyBend(
            points: [
                LegacyBend.Point(time: 0, pitch: 0),
                LegacyBend.Point(time: 60, pitch: 100),
            ],
            play: false,
            lineWidth: 0.2,
        )
        let v4 = note.encode(options: .init(targetVersion: .v4)).first("Bend")
        let v3 = note.encode(options: .init(targetVersion: .v3)).first("Bend")
        #expect(v4 != nil)
        #expect(v4 == v3)
    }

    // MARK: - Helpers

    /// Walk every staff / measure / voice / chord / note in document order,
    /// grace notes included — the same walk `LegacyBendDecodeTests` uses.
    private func legacyBends(in score: Score) -> [LegacyBend] {
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
        .compactMap(\.legacyBend)
    }
}
