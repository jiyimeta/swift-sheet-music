#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    @testable import SheetMusicAudioCore
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicMIDI
    import Testing

    /// A three-measure score whose middle measure repeats, so the unrolled
    /// sequence is longer than the notated one and `PlaybackClock`'s two
    /// conversions are not the identity. A score without a repeat would let a
    /// no-op implementation pass every test below.
    private func repeatingScore() -> Score {
        func quarters(_ pitches: [Int]) -> [VoiceElement] {
            pitches.map { pitch in
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
            }
        }
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [
                        Staff(measures: [
                            Measure(voices: [Voice(elements: quarters([60, 62, 64, 65]))]),
                            Measure(
                                voices: [Voice(elements: quarters([67, 69, 71, 72]))],
                                startRepeat: true,
                                endRepeatCount: 2,
                            ),
                            Measure(voices: [Voice(elements: quarters([64, 62, 60, 60]))]),
                        ]),
                    ],
                ),
            ],
        )
    }

    @Suite("PlaybackClock")
    struct PlaybackClockTests {
        @Test("the repeat makes the player clock longer than the notated one")
        func repeatLengthensThePlayerClock() {
            let clock = PlaybackClock(score: repeatingScore())
            #expect(clock.totalPlayerSeconds > clock.totalNotatedSeconds)
        }

        @Test("notated → player → notated is the identity inside the first pass")
        func roundTripIsIdentityInFirstPass() {
            let clock = PlaybackClock(score: repeatingScore())
            let notated = clock.totalNotatedSeconds * 0.1
            let back = clock.notatedSeconds(
                fromPlayer: clock.playerSeconds(fromNotated: notated),
            )
            #expect(abs(back - notated) < 1e-9)
        }

        @Test("a measure start resolves to a player position and back")
        func measureStartRoundTrips() throws {
            let clock = PlaybackClock(score: repeatingScore())
            let seconds = try #require(clock.playerSeconds(atMeasureIndex: 2))
            #expect(clock.measureIndex(atPlayerSeconds: seconds) == 2)
        }

        /// The third measure sounds AFTER the repeat has played twice, so its
        /// player position has to sit past two measure-plays' worth of the
        /// second measure — not at its notated start. This is the assertion a
        /// clock that ignored the unroll map would fail.
        @Test("the last measure starts later on the player clock than on the notated one")
        func lastMeasureIsPushedBackByTheRepeat() throws {
            let clock = PlaybackClock(score: repeatingScore())
            let player = try #require(clock.playerSeconds(atMeasureIndex: 2))
            let tick = try #require(clock.measureStartTick(2))
            let notated = PlaybackTimeline(score: repeatingScore())
                .seconds(atTick: Double(tick))
            #expect(player > notated)
        }

        @Test("an out-of-range measure index has no player position")
        func outOfRangeMeasureIsNil() {
            let clock = PlaybackClock(score: repeatingScore())
            #expect(clock.playerSeconds(atMeasureIndex: -1) == nil)
            #expect(clock.playerSeconds(atMeasureIndex: 99) == nil)
        }

        @Test("a frame resolves at the top of the score")
        func frameResolvesAtPlayerSeconds() throws {
            let clock = PlaybackClock(score: repeatingScore())
            let frame = try #require(clock.frame(atPlayerSeconds: 0))
            #expect(frame.tick == 0)
        }

        @Test("a negative player position clamps to the top rather than extrapolating")
        func negativePlayerSecondsClamp() {
            let clock = PlaybackClock(score: repeatingScore())
            #expect(clock.notatedSeconds(fromPlayer: -5) == 0)
        }

        /// An unrolled tick belonging to the repeat's SECOND pass must map past
        /// the first pass, not back onto it. Going through
        /// `playerSeconds(fromNotated:)` — which answers with a notated
        /// instant's first occurrence — would return the earlier time and stall
        /// a beat indicator for a whole measure.
        @Test("an unrolled tick in the repeat's second pass lands after the first")
        func secondPassTickLandsAfterTheFirst() throws {
            let score = repeatingScore()
            let clock = PlaybackClock(score: score)
            let unroll = MidiRenderer.playbackUnroll(score: score)
            let spans = unroll.spans
            try #require(spans.count >= 3)
            // spans[1] and spans[2] are the two plays of the repeated measure.
            let first = clock.playerSecondsForUnrolledTick(spans[1].unrolledStart)
            let second = clock.playerSecondsForUnrolledTick(spans[2].unrolledStart)
            #expect(second > first)
        }

        @Test("an unrolled tick past the notated end stays inside the player clock")
        func unrolledTickPastNotatedEndStaysInRange() {
            let clock = PlaybackClock(score: repeatingScore())
            let seconds = clock.playerSecondsForUnrolledTick(0)
            #expect(seconds == 0)
            #expect(clock.playerSecondsForUnrolledTick(-1) == 0)
        }

        @Test("the cache hands back an equal clock for the same handle")
        func cacheReuses() {
            let score = repeatingScore()
            let first = PlaybackClockCache.clock(for: 7, score: score)
            let second = PlaybackClockCache.clock(for: 7, score: score)
            #expect(first.totalPlayerSeconds == second.totalPlayerSeconds)
            PlaybackClockCache.release(7)
        }
    }
#endif
