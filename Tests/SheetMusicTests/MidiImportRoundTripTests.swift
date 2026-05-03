import Foundation
@testable import SheetMusic
@testable import SheetMusicAudio
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct MidiImportRoundTripTests {
    // MARK: - Helpers

    /// Walk all `VoiceElement` chord pitches across every staff/measure/voice.
    private func allPitches(in score: Score) -> [Int] {
        score.staves
            .flatMap(\.measures)
            .flatMap(\.voices)
            .flatMap(\.elements)
            .flatMap { element -> [Int] in
                if case let .chord(chord) = element {
                    return chord.notes.map(\.pitch)
                }
                return []
            }
    }

    // MARK: - Synthetic tests

    @Test func syntheticSingleNoteRoundTrips() throws {
        // Build a Score with one C4 quarter note.
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let voice = Voice(elements: [.chord(chord)])
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "piano", longName: "Piano")
        )
        let originalScore = Score(
            division: 480,
            parts: [part],
            staves: [staff]
        )

        // Round trip: render → SMF bytes → import.
        let smfBytes = try MidiWriter.write(MidiRenderer.render(score: originalScore))
        let imported = try MidiImporter.parse(smfBytes)

        // Verify the imported score has the right shape.
        #expect(imported.parts.count >= 1)
        #expect(!imported.staves.isEmpty)

        let pitches = allPitches(in: imported)
        #expect(pitches.contains(60))
    }

    @Test func syntheticChordRoundTrips() throws {
        // C major triad as a half-note chord.
        let notes: ChordNotes = [
            Note(pitch: 60, tpc: 14),
            Note(pitch: 64, tpc: 18),
            Note(pitch: 67, tpc: 15),
        ]
        let chord = Chord(duration: .half, notes: notes)
        let voice = Voice(elements: [.chord(chord)])
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "piano", longName: "Piano")
        )
        let score = Score(division: 480, parts: [part], staves: [staff])

        let smfBytes = try MidiWriter.write(MidiRenderer.render(score: score))
        let imported = try MidiImporter.parse(smfBytes)

        let pitches = allPitches(in: imported)
        #expect(pitches.contains(60))
        #expect(pitches.contains(64))
        #expect(pitches.contains(67))
    }

    // MARK: - Fixture-based test

    @Test func importedScoreCanBeReRendered() throws {
        // Reported bug: importing then re-rendering trips the
        // MidiWriter `delta >= 0` precondition. Reproduce here.
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let v = Voice(elements: [.chord(chord)])
        let measure = Measure(voices: [v])
        let staff = StaffContent(id: 1, measures: [measure])
        let part = Part(id: "P1", instrument: Instrument(id: "piano"))
        let originalScore = Score(division: 480, parts: [part], staves: [staff])

        let smfBytes = try MidiWriter.write(MidiRenderer.render(score: originalScore))
        let imported = try MidiImporter.parse(smfBytes)
        let rerendered = try MidiRenderer.render(score: imported)
        _ = try MidiWriter.write(rerendered)
    }

    @Test func importedMultiPartScoreWithKeySigCanBeReRendered() throws {
        // Mimic a real-world DAW SMF: multi-track, with a key sig
        // and tempo on track 0. Round-trip through import → re-render
        // must not crash.
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Conductor"))),
            TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 500_000))),
            TimedMidiEvent(tick: 0, event: .meta(.keySignature(sharpsFlats: -2, isMinor: false))),
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Piano"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 70, velocity: 80)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 70, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let track2 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Bass"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 1, pitch: 36, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 1, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1, track2])
        let bytes = try MidiWriter.write(file)
        let imported = try MidiImporter.parse(bytes)
        let rerendered = try MidiRenderer.render(score: imported)
        _ = try MidiWriter.write(rerendered)
    }

    @Test func midi01FixtureRoundTrips() throws {
        guard let url = Bundle.module.url(forResource: "midi01", withExtension: "mscx") else {
            Issue.record("midi01.mscx fixture missing")
            return
        }
        let mscxData = try Data(contentsOf: url)
        let original = try MSCXParser.parse(mscxData)
        let firstBytes = try MidiWriter.write(MidiRenderer.render(score: original))

        // Verify import doesn't throw and produces a plausible Score.
        let imported = try MidiImporter.parse(firstBytes)
        #expect(imported.division > 0)
        #expect(!imported.parts.isEmpty)

        // The imported Score must be re-renderable — playback engine
        // does exactly this and tripped the MidiWriter precondition.
        let rerendered = try MidiRenderer.render(score: imported)
        _ = try MidiWriter.write(rerendered)
    }

    /// Replicates `MetronomeController.metronomeTrack` body without
    /// the AVAudioEngine dependency, so tests can exercise the same
    /// playback bytes the engine would build.
    private func metronomeTrack(beats: [MetronomeBeat], division: Int) -> MidiTrack {
        var events: [TimedMidiEvent] = []
        let halfBeat = max(1, division / 4)
        for beat in beats {
            let pitch = beat.isDownbeat ? 76 : 77
            let velocity = beat.isDownbeat ? 100 : 80
            events.append(TimedMidiEvent(
                tick: beat.tick,
                event: .noteOn(channel: 9, pitch: pitch, velocity: velocity)
            ))
            events.append(TimedMidiEvent(
                tick: beat.tick + halfBeat,
                event: .noteOff(channel: 9, pitch: pitch, velocity: 0)
            ))
        }
        let lastTick = events.map(\.tick).max() ?? 0
        events.append(TimedMidiEvent(tick: lastTick + 1, event: .endOfTrack))
        return MidiTrack(events: events)
    }

    @Test func importedScorePlaybackPipelineDoesNotCrash() throws {
        // Full playback path: render → append metronome → write.
        // PlaybackEngine.buildSequencer does this; user reports it
        // fires the MidiWriter precondition for imported scores.
        guard let url = Bundle.module.url(forResource: "midi01", withExtension: "mscx") else {
            Issue.record("midi01.mscx fixture missing")
            return
        }
        let mscxData = try Data(contentsOf: url)
        let original = try MSCXParser.parse(mscxData)
        let firstBytes = try MidiWriter.write(MidiRenderer.render(score: original))
        let imported = try MidiImporter.parse(firstBytes)

        let beats = PlaybackTimeline.metronomeBeats(score: imported)
        var midi = try MidiRenderer.render(score: imported)
        midi.tracks.append(metronomeTrack(beats: beats, division: midi.division))
        _ = try MidiWriter.write(midi)
    }

    @Test func allMscxFixturesReRenderAfterImport() throws {
        // Walk every .mscx fixture and verify the full round-trip:
        // parse mscx → render → import → re-render → write. Trips
        // immediately on whichever fixture exposes the bug.
        let fixtures = [
            "midi01",
            "midi02",
            "midi03",
            "testArpeggio",
            "testMidiPort",
            "testMutedUnison",
            "testMeasureRepeats",
        ]
        for name in fixtures {
            guard let url = Bundle.module.url(forResource: name, withExtension: "mscx") else {
                continue
            }
            let mscxData = try Data(contentsOf: url)
            let original = try MSCXParser.parse(mscxData)
            let firstBytes = try MidiWriter.write(MidiRenderer.render(score: original))
            let imported = try MidiImporter.parse(firstBytes)
            let rerendered = try MidiRenderer.render(score: imported)
            do {
                _ = try MidiWriter.write(rerendered)
            } catch {
                Issue.record("Re-render failed for \(name): \(error)")
            }
        }
    }
}
