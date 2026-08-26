#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// The click patch and the metronome-only sequence are shared by every backend that schedules clicks off
    /// a transport: the Apple engine, the SwiftySynth backend, and the Android FluidSynth engine (through
    /// `AudioMidiBridge.renderMetronomeMidi`). These tests pin the parts each of them relies on.
    struct MetronomeSequenceBuilderTests {
        private static let division = 480

        private static func score(measureCount: Int = 2) -> Score {
            let measures = (0 ..< measureCount).map { _ in
                Measure(voices: [Voice(elements: [.chord(Chord(
                    duration: .whole,
                    notes: [Note(pitch: 60, tpc: 14)],
                ))])])
            }
            let part = Part(
                id: "P0",
                instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: measures)],
            )
            return Score(division: division, parts: [part])
        }

        // MARK: - Click patch

        @Test func clickTrackUsesTheGMWoodBlocksOnChannel9() {
            let track = MetronomeSequenceBuilder.clickTrack(
                beats: [
                    MetronomeBeat(tick: 0, isDownbeat: true),
                    MetronomeBeat(tick: 480, isDownbeat: false),
                ],
                division: Self.division,
            )

            let noteOns = track.events.compactMap { event -> (Int, Int, Int, Int)? in
                guard case let .noteOn(channel, pitch, velocity) = event.event else { return nil }
                return (event.tick, channel, pitch, velocity)
            }
            // Downbeat: hi wood block, accented. Other beats: low wood block, softer. Android used to fire
            // 96/72 from its own scheduler, which made the same score click differently on the two platforms.
            #expect(noteOns.count == 2)
            #expect(noteOns[0] == (0, 9, 76, 100))
            #expect(noteOns[1] == (480, 9, 77, 80))
        }

        @Test func eachClickIsReleasedAHalfBeatLater() {
            let track = MetronomeSequenceBuilder.clickTrack(
                beats: [MetronomeBeat(tick: 960, isDownbeat: true)],
                division: Self.division,
            )

            let noteOffs = track.events.compactMap { event -> (tick: Int, pitch: Int)? in
                guard case let .noteOff(_, pitch, _) = event.event else { return nil }
                return (event.tick, pitch)
            }
            #expect(noteOffs.count == 1)
            #expect(noteOffs.first?.tick == 960 + Self.division / 4)
            #expect(noteOffs.first?.pitch == 76)
        }

        @Test func emptyBeatsStillProduceAClosedTrack() {
            let track = MetronomeSequenceBuilder.clickTrack(beats: [], division: Self.division)
            #expect(track.events.count == 1)
            #expect(track.events.last?.event == .endOfTrack)
        }

        // MARK: - Metronome-only sequence

        @Test func metronomeOnlySequenceCopiesTheScoresTempoMap() throws {
            let rendered = try MidiRenderer.render(score: Self.score())
            let sequence = MetronomeSequenceBuilder.metronomeOnlySequence(
                rendered: rendered,
                metronomeBeats: PlaybackTimeline.unrolledMetronomeBeats(score: Self.score()),
            )

            #expect(sequence.division == rendered.division)
            #expect(sequence.tracks.count == 2)

            func tempoTicks(_ tracks: [MidiTrack]) -> [Int] {
                tracks.flatMap { track in
                    track.events.compactMap { event in
                        guard case let .meta(meta) = event.event, case .tempo = meta else { return nil }
                        return event.tick
                    }
                }
            }
            // Same tempo map tick-for-tick: this is what keeps the click transport and the score transport
            // reading the same seconds clock while both are advanced by identical frame counts.
            #expect(!tempoTicks(sequence.tracks).isEmpty)
            #expect(tempoTicks(sequence.tracks) == tempoTicks(rendered.tracks).sorted())
        }

        @Test func metronomeOnlySequenceCarriesNoScoreNotes() throws {
            let score = Self.score()
            let rendered = try MidiRenderer.render(score: score)
            let sequence = MetronomeSequenceBuilder.metronomeOnlySequence(
                rendered: rendered,
                metronomeBeats: PlaybackTimeline.unrolledMetronomeBeats(score: score),
            )

            // The conductor track is meta-only — a stray note here would sound on the metronome synth,
            // which is loaded with the click SoundFont rather than the score's.
            let conductorNotes = sequence.tracks[0].events.filter { event in
                if case .noteOn = event.event { return true }
                return false
            }
            #expect(conductorNotes.isEmpty)
        }

        @Test func preRollClicksFillTheRegionAheadOfTheBodyWhenAsked() throws {
            let score = Self.score()
            let rendered = try MidiRenderer.render(score: score)
            let plan = CountInBeats.Result(
                preRollTicks: 1920,
                beats: [
                    MetronomeBeat(tick: 0, isDownbeat: true),
                    MetronomeBeat(tick: 480, isDownbeat: false),
                ],
                quarterBpm: 120,
            )
            let sequence = MetronomeSequenceBuilder.metronomeOnlySequence(
                rendered: rendered,
                metronomeBeats: [MetronomeBeat(tick: 0, isDownbeat: true)],
                plan: plan,
                baseTick: 0,
                includingPreRollClicks: true,
            )

            let clickTicks = sequence.tracks[1].events.compactMap { event -> Int? in
                guard case .noteOn = event.event else { return nil }
                return event.tick
            }
            // The count's own clicks sit in `[0, preRollTicks)`, the body's behind them. One transport plays
            // both, which is what puts the count-in on the audio clock instead of a wall-clock wait.
            #expect(clickTicks == [0, 480, 1920])
        }

        @Test func countInPlanShiftsClicksAndTempoPastThePreRoll() throws {
            let score = Self.score()
            let rendered = try MidiRenderer.render(score: score)
            let plan = CountInBeats.Result(
                preRollTicks: 1920,
                beats: [MetronomeBeat(tick: 0, isDownbeat: true)],
                quarterBpm: 120,
            )
            let sequence = MetronomeSequenceBuilder.metronomeOnlySequence(
                rendered: rendered,
                metronomeBeats: [MetronomeBeat(tick: 0, isDownbeat: true)],
                plan: plan,
                baseTick: 0,
            )

            let clickTicks = sequence.tracks[1].events.compactMap { event -> Int? in
                guard case .noteOn = event.event else { return nil }
                return event.tick
            }
            // The body click that was at score tick 0 now sounds where the music does — after the pre-roll.
            #expect(clickTicks == [1920])
            // ...and a governing tempo is seeded at tick 0 so the pre-roll region itself has a tempo.
            #expect(sequence.tracks[0].events.first?.tick == 0)
        }

        // MARK: - Android bridge

        @Test func androidBridgeRendersAPlayableMetronomeSMF() throws {
            let score = Self.score()
            let bytes = try AudioMidiBridge.renderMetronomeMidi(score: score)
            #expect(!bytes.isEmpty)

            // Round-trips as a real SMF: this is what `fluid_player_add_mem` is handed.
            let parsed = try MidiReader.read(bytes)
            #expect(parsed.division == score.division)

            let clickTicks = parsed.tracks.flatMap { track in
                track.events.compactMap { event -> Int? in
                    guard case let .noteOn(channel, _, _) = event.event, channel == 9 else { return nil }
                    return event.tick
                }
            }
            #expect(clickTicks == PlaybackTimeline.unrolledMetronomeBeats(score: score).map(\.tick))
        }

        @Test func androidBridgeRendersACountInSequenceAheadOfTheBody() throws {
            let score = Self.score()
            let cursor = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 0)
            let bytes = try AudioMidiBridge.renderCountInMetronomeMidi(
                score: score, cursor: cursor, baseTick: 0,
            )
            #expect(!bytes.isEmpty)

            let parsed = try MidiReader.read(bytes)
            let clickTicks = parsed.tracks.flatMap { track in
                track.events.compactMap { event -> Int? in
                    guard case let .noteOn(channel, _, _) = event.event, channel == 9 else { return nil }
                    return event.tick
                }
            }
            let plan = try #require(CountInBeats.compute(score: score, startCursor: cursor))
            // Everything before the pre-roll's end is the count itself; everything at or after it is the
            // body, pushed back by exactly the region the count occupies.
            #expect(clickTicks.filter { $0 < plan.preRollTicks } == plan.beats.map(\.tick))
            #expect(clickTicks.contains(plan.preRollTicks))
        }
    }
#endif
