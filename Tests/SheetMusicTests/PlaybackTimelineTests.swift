#if !os(Android)
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import Testing

    @Suite("PlaybackTimeline")
    struct PlaybackTimelineTests {
        /// Regression: `frame(forCursor:)` used to do an exact-ID match
        /// against `frames`, which only carry one representative item
        /// per unique tick (lowest staff / voice wins the dedup). A
        /// selection on any other staff returned `nil`, and pressing
        /// space silently failed to update the sequencer position.
        /// Two-part score where each part has one staff with two chords.
        private func twoPartTwoChordScore() -> Score {
            let chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
            let voice = Voice(elements: [.chord(chord), .chord(chord)])
            let staff = Staff(measures: [Measure(voices: [voice])])
            let instrument = Instrument(id: "i", articulations: [InstrumentArticulation()])
            return Score(
                division: 480,
                parts: [
                    Part(id: "P1", instrument: instrument, staves: [staff]),
                    Part(id: "P2", instrument: instrument, staves: [staff]),
                ],
            )
        }

        @Test("frame(forCursor:) resolves notes on non-representative staves")
        func nonRepresentativeStaffLookup() {
            let score = twoPartTwoChordScore()
            let timeline = PlaybackTimeline(score: score)

            // Two staves × two unique chord ticks → 2 frames after dedup.
            // Beat-only frames at ticks 0 and 480 already exist as
            // chord onsets, so no extra beat frames are added in this
            // densely-packed measure.
            let chordTicks = timeline.frames
                .filter {
                    if case .item = $0.cursor { return true }
                    return false
                }
                .map(\.tick)
            #expect(chordTicks == [0, 480])

            // Every chord-onset frame's representative belongs to staff 0
            // (lowest index wins).
            for frame in timeline.frames {
                if case let .item(.note(id)) = frame.cursor {
                    #expect(id.staff.partIndex == 0)
                }
            }

            // Staff 0 lookup hits the exact-match path.
            let s0n0 = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
                voiceIndex: 0, elementIndex: 0,
                noteIndexInChord: 0,
            )
            #expect(timeline.frame(forCursor: .item(.note(s0n0)))?.tick == 0)

            // Staff 1 lookups must hit the tick-fallback path. Without
            // the fix these returned nil.
            let s1n0 = NoteID(
                staff: StaffAddress(partIndex: 1, staffIndexInPart: 0), measureIndex: 0,
                voiceIndex: 0, elementIndex: 0,
                noteIndexInChord: 0,
            )
            let s1n1 = NoteID(
                staff: StaffAddress(partIndex: 1, staffIndexInPart: 0), measureIndex: 0,
                voiceIndex: 0, elementIndex: 1,
                noteIndexInChord: 0,
            )
            #expect(timeline.frame(forCursor: .item(.note(s1n0)))?.tick == 0)
            #expect(timeline.frame(forCursor: .item(.note(s1n1)))?.tick == 480)
        }

        @Test("earliest(of:) picks the smaller-tick item regardless of input order")
        func earliestPicksSmallestTick() {
            let chord = Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )
            let voice = Voice(elements: [
                .chord(chord), .chord(chord), .chord(chord),
            ])
            let staff = Staff(
                measures: [Measure(voices: [voice])],
            )
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(
                division: 480, parts: [part],
            )

            let timeline = PlaybackTimeline(score: score)

            let n0 = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
                voiceIndex: 0, elementIndex: 0,
                noteIndexInChord: 0,
            )
            let n2 = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
                voiceIndex: 0, elementIndex: 2,
                noteIndexInChord: 0,
            )

            // Anchor-then-target order: target is later → earliest is anchor.
            #expect(timeline.earliest(of: [.note(n0), .note(n2)]) == .note(n0))
            // Reverse order (user shift-clicked an earlier note last) →
            // earliest must still be the chronologically earlier note.
            #expect(timeline.earliest(of: [.note(n2), .note(n0)]) == .note(n0))
            // Empty / unknown items → nil (host falls back to anchor).
            #expect(timeline.earliest(of: []) == nil)
        }

        @Test("itemTicks covers every note in a chord, not just the first")
        func chordMembersAllMapped() {
            let chord = Chord(
                duration: .quarter,
                notes: [
                    Note(pitch: 60, tpc: 14),
                    Note(pitch: 64, tpc: 18),
                    Note(pitch: 67, tpc: 15),
                ],
            )
            let voice = Voice(elements: [.chord(chord)])
            let staff = Staff(
                measures: [Measure(voices: [voice])],
            )
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(
                division: 480, parts: [part],
            )

            let timeline = PlaybackTimeline(score: score)

            // Every chord-member NoteID maps to tick 0 — the user can
            // click any note in a chord and seek to that column.
            for noteIdx in 0 ..< 3 {
                let id = NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
                    voiceIndex: 0, elementIndex: 0,
                    noteIndexInChord: noteIdx,
                )
                #expect(timeline.frame(forCursor: .item(.note(id)))?.tick == 0)
            }
        }

        /// In a measure of 4/4 holding "half + 8th + 8th + quarter",
        /// chord/rest onsets are at ticks {0, 960, 1200, 1440}. The
        /// metric-beat grid is at {0, 480, 960, 1440}. The cursor
        /// timeline must contain the union: {0, 480, 960, 1200, 1440}.
        /// The beat-only tick (480) lands as a `.beat` cursor; the
        /// others as `.item`.
        @Test("Beat ticks fill in between chord onsets per time-sig denominator")
        func beatTicksAddedBetweenOnsets() {
            let half = Chord(
                duration: .half, notes: [Note(pitch: 60, tpc: 14)],
            )
            let eighth = Chord(
                duration: .eighth, notes: [Note(pitch: 60, tpc: 14)],
            )
            let quarter = Chord(
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)],
            )
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(half),
                .chord(eighth),
                .chord(eighth),
                .chord(quarter),
            ])
            let staff = Staff(
                measures: [Measure(voices: [voice])],
            )
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(
                division: 480, parts: [part],
            )

            let timeline = PlaybackTimeline(score: score)
            let ticks = timeline.frames.map(\.tick)
            #expect(ticks == [0, 480, 960, 1200, 1440])

            // The 480 tick must be a `.beat` cursor. The 0 / 960 / 1200 /
            // 1440 ticks must be `.item` cursors (chord onsets win the
            // dedup since their sortKey beats the beat sentinel).
            for frame in timeline.frames {
                switch frame.tick {
                case 480:
                    #expect(frame.cursor == .beat(
                        measureIndex: 0, tickInMeasure: 480,
                    ))
                default:
                    if case .item = frame.cursor { } else {
                        Issue.record("Expected .item at tick \(frame.tick), got \(frame.cursor)")
                    }
                }
            }
        }

        /// Regression for the idea8.mscx playback-cursor drift: a `<Tempo>`
        /// preceded by `<location>` shifts (e.g. `rit. … a tempo` clusters)
        /// must land at the shifted tick, not the chord-walk tick. The
        /// MIDI sequencer respects the location shift, so if the timeline
        /// records the tempo at the wrong tick its `timeSeconds` drifts
        /// away from `currentPositionInSeconds` and the cursor jumps
        /// ahead of the audio at later beats.
        @Test("locationShift before a Tempo offsets the tempo's tick")
        func locationShiftMovesTempoTick() {
            let half = Chord(
                duration: .half, notes: [Note(pitch: 60, tpc: 14)],
            )
            // 4/4 measure: half | locShift(+1/8) | tempo→60bpm | locShift(-1/8) | half.
            // With division=480, +1/8 = +240 ticks. Without the fix, the
            // tempo lands at tick 480 (chord-walk position) instead of 720.
            // Tempo lives on the score-level SystemMeasure at position
            // 5/8 (half + eighth = 720 ticks at division=480). The voice
            // stream itself only carries the two half-notes.
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(half),
                .chord(half),
            ])
            let staff = Staff(measures: [Measure(voices: [voice])])
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let systemMeasure = SystemMeasure(elements: [
                PositionedSystemElement(
                    position: MeasurePosition(numerator: 5, denominator: 8),
                    element: .tempo(Tempo(beatsPerSecond: 1.0)),
                ),
            ])
            let score = Score(
                division: 480, parts: [part],
                systemMeasures: [systemMeasure],
            )
            let timeline = PlaybackTimeline(score: score)

            // Frame at the second half-note onset (tick 960). With the
            // tempo correctly placed at tick 720:
            //   0..720  @ 120 bpm (default) = 720 / (2 * 480) = 0.75 s
            //   720..960 @ 60 bpm           = 240 / (1 * 480) = 0.50 s
            // total = 1.25 s. With the bug (tempo at tick 480) it'd be
            // 0.5 + 1.0 = 1.5 s.
            // A frame at the second chord onset (tick 960) is reached
            // before the tempo fires in either branch — what matters is
            // the *total* runtime past the bracketed tempo. With the fix,
            // tempo lands at tick 1200; the final 720 ticks play at 60 bpm,
            // giving total = 1.25 + 1.5 = 2.75 s. Without the fix the
            // tempo lands at tick 960 and the final 960 ticks play at
            // 60 bpm, giving 1.0 + 2.0 = 3.0 s.
            #expect(abs(timeline.totalSeconds - 2.75) < 1e-9)
        }

        /// Regression for the idea8.mscx playback-cursor "lead" symptom:
        /// when the lowest staff carries a whole-measure rest, the
        /// engraver renders that rest *centered* in the bar (not at the
        /// rhythmic onset column), so a `.item(.rest)` cursor on it
        /// would park visually around beat 2.5 while audio is still on
        /// beat 1. The timeline must skip whole-note rests so a chord
        /// onset on another staff wins the cursor-frame slot at tick 0.
        @Test("Whole-measure rest on staff 0 does not win the cursor at its tick")
        func wholeRestSkippedInPending() {
            let restWhole = Chord(
                duration: .fraction(Fraction(numerator: 4, denominator: 4)),
                notes: [],
            )
            let quarter = Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )
            // Staff 0: whole-measure rest only. Staff 1: 4 quarter notes.
            let staff0 = Staff(
                measures: [Measure(voices: [Voice(elements: [.chord(restWhole)])])],
            )
            let staff1 = Staff(measures: [Measure(voices: [Voice(elements: [
                .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
            ])])])
            let instrument = Instrument(
                id: "i", articulations: [InstrumentArticulation()],
            )
            let score = Score(
                division: 480,
                parts: [
                    Part(id: "P0", instrument: instrument, staves: [staff0]),
                    Part(id: "P1", instrument: instrument, staves: [staff1]),
                ],
            )
            let timeline = PlaybackTimeline(score: score)

            // Tick 0 must resolve to the staff 1 chord, not the staff 0
            // whole-rest. Without the skip, dedup would prefer staff 0's
            // rest (sortKey (0, 0) wins over staff 1's (1, 0)) and the
            // cursor would render at the centered rest glyph.
            let frame0 = timeline.frame(atTick: 0)
            if case let .item(.note(id)) = frame0?.cursor {
                #expect(id.staff.partIndex == 1)
            } else {
                Issue.record(
                    "Expected .item(.note) on staff 1 at tick 0, got \(String(describing: frame0?.cursor))",
                )
            }

            // The whole-measure rest is still seekable via
            // `frame(forCursor:)` — `itemTicks` keeps mapping it so
            // play-from-selection on the rest still works.
            let restID = RestID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
            )
            #expect(timeline.frame(forCursor: .item(.rest(restID)))?.tick == 0)
        }

        /// 6/8 → step = division / 2 (eighth ticks), 6 beats per measure.
        @Test("6/8 emits beats at the eighth-note interval, six per measure")
        func compoundTimeSigBeatStep() {
            let qDot = Chord(
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)],
            )
            // Fill a 6/8 measure with three quarter notes — chord onsets
            // at ticks 0, 480, 960; missing beat ticks at 240, 720, 1200.
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 6, denominator: 8)),
                .chord(qDot), .chord(qDot), .chord(qDot),
            ])
            let staff = Staff(
                measures: [Measure(voices: [voice])],
            )
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(
                division: 480, parts: [part],
            )

            let timeline = PlaybackTimeline(score: score)
            let ticks = timeline.frames.map(\.tick)
            #expect(ticks == [0, 240, 480, 720, 960, 1200])
        }

        /// `seconds(atTick:)` is the *continuous* counterpart to
        /// `frame(atTick:)`: where the latter snaps to a note/beat onset,
        /// this linearly interpolates between the bracketing frames so a
        /// caller can scroll a playhead smoothly. Expected values are
        /// derived from the timeline's own frames so the test is robust to
        /// timing-model tweaks, and the score has no tempo changes — so
        /// time is linear in tick and the midpoint checks are exact.
        @Test("seconds(atTick:) interpolates continuous time between frames")
        func secondsAtTickInterpolatesBetweenFrames() {
            // 4/4 of four quarter notes at division 480, default 120 bpm:
            // onset frames at ticks 0/480/960/1440 (0.0/0.5/1.0/1.5 s);
            // the final quarter rings out to tick 1920 (2.0 s).
            let quarter = Chord(
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)],
            )
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
            ])
            let staff = Staff(measures: [Measure(voices: [voice])])
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i", articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let timeline = PlaybackTimeline(score: Score(division: 480, parts: [part]))

            let frames = timeline.frames
            #expect(frames.count >= 2)
            let first = frames[0]
            let last = frames[frames.count - 1]
            // The final note rings out past the last onset frame, so the
            // extrapolation segment [last.tick, totalTicks] is non-empty.
            #expect(timeline.totalTicks > last.tick)

            // Exact at any frame tick returns that frame's own time.
            for f in frames {
                #expect(abs(timeline.seconds(atTick: Double(f.tick)) - f.timeSeconds) < 1e-9)
            }

            // Midpoint between two consecutive frames is the midpoint in
            // time (constant tempo ⇒ linear in tick).
            let a = frames[0], b = frames[1]
            let midTick = Double(a.tick + b.tick) / 2
            let midExpected = (a.timeSeconds + b.timeSeconds) / 2
            #expect(abs(timeline.seconds(atTick: midTick) - midExpected) < 1e-9)

            // Before the first frame clamps to the first frame's time.
            #expect(timeline.seconds(atTick: Double(first.tick) - 100) == first.timeSeconds)

            // Extrapolation past the last onset frame: at totalTicks it
            // reaches totalSeconds, and the segment midpoint is half-way.
            #expect(abs(timeline.seconds(atTick: Double(timeline.totalTicks)) - timeline.totalSeconds) < 1e-9)
            let tailMid = Double(last.tick + timeline.totalTicks) / 2
            let tailExpected = last.timeSeconds
                + 0.5 * (timeline.totalSeconds - last.timeSeconds)
            #expect(abs(timeline.seconds(atTick: tailMid) - tailExpected) < 1e-9)

            // Far beyond the end clamps (the fraction is capped at 1).
            #expect(abs(
                timeline.seconds(atTick: Double(timeline.totalTicks) + 10000)
                    - timeline.totalSeconds,
            ) < 1e-9)
        }
    }
#endif
