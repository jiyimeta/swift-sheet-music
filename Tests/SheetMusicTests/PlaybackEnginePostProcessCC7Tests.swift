#if !os(Android)
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// Regression test for per-staff volume override being reset during
    /// loop playback (and audio-file export).
    ///
    /// Root cause: the rendered SMF carries the score's baked-in CC 7
    /// (Channel Volume) at tick 0. Every backward seek across / behind
    /// tick 0 — the loop-wrap rewind in `tickCursor`, the export
    /// sequencer's initial start — makes AVAudioSequencer chase and
    /// re-fire that tick-0 CC 7 on the render thread, clobbering the
    /// live mixer's volume with the score default. Re-applying the mixer
    /// *after* `sequencer.start()` races that chase and loses.
    ///
    /// The robust fix removes the competing source: for the channels the
    /// mixer owns (each staff's primary channel), CC 7 is stripped from
    /// the bytes handed to `AVAudioSequencer`, so `applyMixerState()` is
    /// the *sole* authority on those channels' volume — deterministic,
    /// no race. Secondary playback-flavour channels (e.g. a string
    /// part's pizz channel) are NOT managed by the mixer, so their CC 7
    /// must survive to keep the score's volume balance.
    @Suite("PlaybackEngine post-process CC 7 stripping")
    struct PlaybackEnginePostProcessCC7Tests {
        @Test("strips CC 7 only on mixer-managed (primary staff) channels")
        func stripsCC7OnManagedChannelsOnly() throws {
            // A single part with two playback flavours: the renderer
            // assigns the primary flavour MIDI channel 0 and the second
            // channel 1. The mixer manages only the primary (ch 0).
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
            ])
            let part = Part(
                id: "p",
                instrument: Instrument(
                    id: "i",
                    channels: [
                        InstrumentChannel(program: 40, volume: 80),
                        InstrumentChannel(program: 45, volume: 40),
                    ],
                ),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )
            let score = Score(division: 480, parts: [part])

            let managed = Set(MidiRenderer.staffChannels(score: score))
            #expect(managed == [0])

            var midi = try MidiRenderer.render(score: score)

            // Sanity: before post-processing, CC 7 exists on both the
            // managed primary channel and the unmanaged second channel.
            #expect(cc7Count(in: midi, channel: 0) > 0)
            #expect(cc7Count(in: midi, channel: 1) > 0)

            PlaybackEngine.postProcessForMIDISynth(
                midi: &midi, mixerManagedChannels: managed,
            )

            // After: the managed channel's CC 7 is gone (mixer owns it),
            // the unmanaged channel's CC 7 survives (score owns it).
            #expect(cc7Count(in: midi, channel: 0) == 0)
            #expect(cc7Count(in: midi, channel: 1) > 0)
        }

        @Test("leaves non-CC-7 events on managed channels untouched")
        func keepsOtherEventsOnManagedChannels() throws {
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
            ])
            let part = Part(
                id: "p",
                instrument: Instrument(
                    id: "i", channels: [InstrumentChannel(program: 0, volume: 90)],
                ),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )
            let score = Score(division: 480, parts: [part])
            var midi = try MidiRenderer.render(score: score)

            let noteOnsBefore = eventCount(in: midi) { event in
                if case .noteOn = event { return true }
                return false
            }
            let pcBefore = eventCount(in: midi) { event in
                if case .programChange = event { return true }
                return false
            }

            PlaybackEngine.postProcessForMIDISynth(
                midi: &midi, mixerManagedChannels: [0],
            )

            // noteOn / programChange on the managed channel are
            // preserved — only CC 7 is removed.
            #expect(eventCount(in: midi) { event in
                if case .noteOn = event { return true }
                return false
            } == noteOnsBefore)
            #expect(eventCount(in: midi) { event in
                if case .programChange = event { return true }
                return false
            } == pcBefore)
            #expect(cc7Count(in: midi, channel: 0) == 0)
        }

        private func cc7Count(in midi: MidiFile, channel: Int) -> Int {
            eventCount(in: midi) { event in
                if case let .controlChange(ch, controller, _) = event {
                    return ch == channel && controller == 7
                }
                return false
            }
        }

        private func eventCount(
            in midi: MidiFile, where predicate: (MidiEvent) -> Bool,
        ) -> Int {
            midi.tracks.reduce(0) { total, track in
                total + track.events.count(where: { predicate($0.event) })
            }
        }
    }
#endif
