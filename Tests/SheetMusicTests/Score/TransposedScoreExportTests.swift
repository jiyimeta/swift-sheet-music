import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// A score transposed with `Score.transposed(bySemitones:)` must reach every serializer in its *new* key — the
/// transform is a plain `Score → Score`, so an export that still reads the original key means the caller handed the
/// pre-transpose score to the exporter, not that the transform failed. These tests pin the library half of that
/// contract (transform → encode → reparse), so a regression here is unambiguously a library bug.
@Suite("Transposed score export")
struct TransposedScoreExportTests {
    private func fixture() throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData("testRepeatsWithKeySigs"))
    }

    /// The key in effect in each measure of the first staff. Compared instead of the raw `<KeySig>` element list
    /// because an implicit C-major key at the staff head is deliberately not serialized (MuseScore Studio renders a
    /// written `<KeySig><concertKey>0</concertKey></KeySig>` there as a redundant natural sign), so a transpose that
    /// lands on C loses an element without losing the key.
    private func keyPerMeasure(_ score: Score) -> [Int] {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        guard let staff = score[address] else { return [] }
        return staff.measures.indices.map {
            score.activeKey(staff: address, measureIndex: $0)
        }
    }

    private func firstNotePitch(_ score: Score) -> Int? {
        for measure in score.parts.first?.staves.first?.measures ?? [] {
            for voice in measure.voices {
                for element in voice.elements {
                    if case let .chord(c) = element, let note = c.notes.first { return note.pitch }
                }
            }
        }
        return nil
    }

    @Test("MSCX export of a transposed score carries the transposed key signatures")
    func mscxExportKeepsTransposedKeys() throws {
        let original = try fixture()
        let transposed = original.transposed(bySemitones: 2)
        #expect(keyPerMeasure(transposed) != keyPerMeasure(original))

        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(transposed))

        #expect(keyPerMeasure(reparsed) == keyPerMeasure(transposed))
        #expect(firstNotePitch(reparsed) == firstNotePitch(transposed))
    }

    @Test("MSCZ export of a transposed score carries the transposed key signatures")
    func msczExportKeepsTransposedKeys() throws {
        let transposed = try fixture().transposed(bySemitones: -3)

        let reparsed = try MSCZReader.parse(MSCZWriter.write(score: transposed))

        #expect(keyPerMeasure(reparsed) == keyPerMeasure(transposed))
        #expect(firstNotePitch(reparsed) == firstNotePitch(transposed))
    }

    @Test("MIDI export of a transposed score emits the transposed pitches")
    func midiExportKeepsTransposedPitches() throws {
        let original = try fixture()
        let transposed = original.transposed(bySemitones: 5)

        func firstNoteOnPitch(_ score: Score) throws -> Int? {
            let file = try MidiRenderer.render(score: score)
            for track in file.tracks {
                for timed in track.events {
                    if case let .noteOn(_, pitch, velocity) = timed.event, velocity > 0 {
                        return pitch
                    }
                }
            }
            return nil
        }

        let before = try #require(try firstNoteOnPitch(original))
        let after = try #require(try firstNoteOnPitch(transposed))
        #expect(after == before + 5)
    }
}
