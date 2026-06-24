#if !os(Android)
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// Regression test for the loop-wrap path dropping the live mixer
    /// state. When `tickCursor` wraps the playhead back to the loop
    /// start it seeks backward across tick 0, which makes
    /// AVAudioSequencer re-fire the SMF's tick-0 controllers (CC 7
    /// volume, program changes) — clobbering the user's mixer choices
    /// with the score's baked-in defaults. `play(from:in:)` already
    /// re-asserts the mixer after its own `sequencer.start()`; the wrap
    /// must do the same.
    ///
    /// The reported symptom is per-staff CC 7 volume reverting on wrap,
    /// but staff CC 7 lives only inside the opaque AUMIDISynth and can't
    /// be read back in a unit test. The metronome-enabled flag is the
    /// observable proxy: it is pushed by the *same* `applyMixerState`
    /// call, so asserting it survives the wrap proves the re-assertion
    /// runs for every channel.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine loop-wrap mixer re-apply")
        @MainActor
        struct PlaybackEngineLoopWrapMixerTests {
            @Test("loop wrap re-applies live mixer state so per-channel choices survive the rewind")
            func loopWrapReassertsMixerState() throws {
                let quarter = Chord(
                    duration: .quarter, notes: [Note(pitch: 60, tpc: 14)],
                )
                let voice = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                ])
                let part = Part(
                    id: "p",
                    instrument: Instrument(
                        id: "i",
                        channels: [InstrumentChannel(program: 0)],
                    ),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )
                let score = Score(division: 480, parts: [part])

                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                try engine.prepare(score: score)
                // Build the sequencer (and attach the metronome track) the
                // way a real play does, then halt the cursor timer so the
                // wrap below is driven deterministically rather than by the
                // 30 Hz poll.
                engine.play(in: score)
                engine.stop()

                // The user mutes the metronome strip — a per-channel mixer
                // choice that must outlive a loop wrap. `applyMixerState`
                // pushes it to the live graph (metronome disabled).
                engine.setMuted(forChannel: .metronome, to: true)
                #expect(engine.exportEngineSnapshot().metronomeEnabled == false)

                // Simulate the SMF's tick-0 events — re-fired by the
                // backward seek — clobbering the live state back to the
                // score default (metronome re-enabled).
                engine.setMetronomeEnabled(true)
                #expect(engine.exportEngineSnapshot().metronomeEnabled == true)

                // Wrap back to the loop start. This is the path the bug
                // lived in: it must re-assert the live mixer state after the
                // rewind, restoring the user's muted-metronome choice.
                engine.wrapToLoopStart(LoopRange(startTick: 0, endTick: 480))

                #expect(engine.exportEngineSnapshot().metronomeEnabled == false)
            }
        }
    }

    private struct NullResolver: SoundfontResolver {
        func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }
#endif
