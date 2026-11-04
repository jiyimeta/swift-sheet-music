import Foundation
import SheetMusicAudioCore
@_spi(PlaybackProbe) @testable import SheetMusicAudioWindows
import SheetMusicCore
import Testing

/// A tap on a beat sounds everything that starts there — a chord's every key, and the other voice's note with it — as
/// one audition, as the Apple engine's `playPreview(noteIDs:)` does (`PlaybackEngineOnsetPreviewTests`). Against a real
/// General MIDI font (`SSM_TEST_SF2`), counting the score synth's voices, since a silent placeholder font sounds none.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SSM_TEST_SF2"] != nil))
struct OnsetPreviewTests {
    static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    struct OneFont: SoundfontResolver {
        let url: URL

        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            url
        }

        var defaultGMSoundfontURL: URL? {
            url
        }
    }

    /// One staff, two voices: voice 1 an E–G dyad then a rest, voice 2 a C then an A.
    static func score() -> Score {
        let upper = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 2, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18), Note(pitch: 67, tpc: 15)])),
            .chord(Chord(duration: .quarter, notes: [])),
        ])
        let lower = Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 69, tpc: 17)])),
        ])
        let staff = Staff(measures: [Measure(voices: [upper, lower])])
        return Score(division: 480, parts: [Part(id: "p0", instrument: Instrument(id: "i"), staves: [staff])])
    }

    /// The score synth's voices a short while after `preview` struck.
    static func voices(after preview: (WindowsPlaybackEngine, Score) -> Void) throws -> Int {
        let path = try #require(ProcessInfo.processInfo.environment["SSM_TEST_SF2"])
        let engine = WindowsPlaybackEngine(
            soundfontResolver: OneFont(url: URL(fileURLWithPath: path)), output: .offline(sampleRate: 44100),
        )
        defer { engine.teardown() }
        let score = Self.score()
        try engine.prepare(score: score)
        preview(engine, score)
        CountInTransportTests.pull(engine, seconds: 0.05)
        return engine.probeActiveVoices[0]
    }

    @Test func aTapOnABeatSoundsEveryNoteThatStartsThere() throws {
        let one = try Self.voices { engine, score in
            engine.playPreview(noteID: NoteID(
                staff: Self.staff, measureIndex: 0, voiceIndex: 1, elementIndex: 0, noteIndexInChord: 0,
            ), in: score)
        }
        let beat = try Self.voices { engine, score in
            let ids = score.onsetNoteIDs(of: .note(NoteID(
                staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            )))
            #expect(ids.count == 3, "the dyad and the other voice's C")
            engine.playPreview(noteIDs: ids, in: score)
        }
        #expect(one > 0, "a single note sounds")
        // Three keys where one sounded one: every key of the beat struck (a GM piano can sound more than one voice per
        // key, so the ratio, not an exact count).
        #expect(beat >= 3 * one, "one key: \(one) voices, the beat: \(beat)")
    }

    @Test func theNextTapCutsTheWholeBeat() throws {
        let left = try Self.voices { engine, score in
            let ids = score.onsetNoteIDs(of: .note(NoteID(
                staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            )))
            engine.playPreview(noteIDs: ids, in: score, duration: 5)
            CountInTransportTests.pull(engine, seconds: 0.05)
            engine.playPreview(noteID: NoteID(
                staff: Self.staff, measureIndex: 0, voiceIndex: 1, elementIndex: 1, noteIndexInChord: 0,
            ), in: score, duration: 5)
            // Past the superseded notes' release.
            CountInTransportTests.pull(engine, seconds: 1.5)
        }
        let alone = try Self.voices { engine, score in
            engine.playPreview(noteID: NoteID(
                staff: Self.staff, measureIndex: 0, voiceIndex: 1, elementIndex: 1, noteIndexInChord: 0,
            ), in: score, duration: 5)
            CountInTransportTests.pull(engine, seconds: 1.5)
        }
        // What is left sounding is the last tap's note, nothing of the beat before it.
        #expect(left == alone, "after the second tap: \(left) voices, that note alone: \(alone)")
    }
}
