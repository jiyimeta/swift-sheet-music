@testable import SheetMusicAudio
import SheetMusicCore
import Testing

@Suite("PlaybackTimeline")
struct PlaybackTimelineTests {
    /// Regression: `frame(forCursor:)` used to do an exact-ID match
    /// against `frames`, which only carry one representative item
    /// per unique tick (lowest staff / voice wins the dedup). A
    /// selection on any other staff returned `nil`, and pressing
    /// space silently failed to update the sequencer position.
    @Test("frame(forCursor:) resolves notes on non-representative staves")
    func nonRepresentativeStaffLookup() {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)]
        )
        let voice = Voice(elements: [
            .chord(chord), .chord(chord),
        ])
        let staff0 = StaffContent(
            id: 1, measures: [Measure(voices: [voice])]
        )
        let staff1 = StaffContent(
            id: 2, measures: [Measure(voices: [voice])]
        )
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()]
            )
        )
        let score = Score(
            division: 480,
            parts: [part, part],
            staves: [staff0, staff1]
        )

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
                #expect(id.staffIndex == 0)
            }
        }

        // Staff 0 lookup hits the exact-match path.
        let s0n0 = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 0,
            noteIndexInChord: 0
        )
        #expect(timeline.frame(forCursor: .item(.note(s0n0)))?.tick == 0)

        // Staff 1 lookups must hit the tick-fallback path. Without
        // the fix these returned nil.
        let s1n0 = NoteID(
            staffIndex: 1, measureIndex: 0,
            voiceIndex: 0, elementIndex: 0,
            noteIndexInChord: 0
        )
        let s1n1 = NoteID(
            staffIndex: 1, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1,
            noteIndexInChord: 0
        )
        #expect(timeline.frame(forCursor: .item(.note(s1n0)))?.tick == 0)
        #expect(timeline.frame(forCursor: .item(.note(s1n1)))?.tick == 480)
    }

    @Test("earliest(of:) picks the smaller-tick item regardless of input order")
    func earliestPicksSmallestTick() {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)]
        )
        let voice = Voice(elements: [
            .chord(chord), .chord(chord), .chord(chord),
        ])
        let staff = StaffContent(
            id: 1, measures: [Measure(voices: [voice])]
        )
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()]
            )
        )
        let score = Score(
            division: 480, parts: [part], staves: [staff]
        )

        let timeline = PlaybackTimeline(score: score)

        let n0 = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 0,
            noteIndexInChord: 0
        )
        let n2 = NoteID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2,
            noteIndexInChord: 0
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
            ]
        )
        let voice = Voice(elements: [.chord(chord)])
        let staff = StaffContent(
            id: 1, measures: [Measure(voices: [voice])]
        )
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()]
            )
        )
        let score = Score(
            division: 480,
            parts: [part], staves: [staff]
        )

        let timeline = PlaybackTimeline(score: score)

        // Every chord-member NoteID maps to tick 0 — the user can
        // click any note in a chord and seek to that column.
        for noteIdx in 0 ..< 3 {
            let id = NoteID(
                staffIndex: 0, measureIndex: 0,
                voiceIndex: 0, elementIndex: 0,
                noteIndexInChord: noteIdx
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
            duration: .half, notes: [Note(pitch: 60, tpc: 14)]
        )
        let eighth = Chord(
            duration: .eighth, notes: [Note(pitch: 60, tpc: 14)]
        )
        let quarter = Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]
        )
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(half),
            .chord(eighth),
            .chord(eighth),
            .chord(quarter),
        ])
        let staff = StaffContent(
            id: 1, measures: [Measure(voices: [voice])]
        )
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()]
            )
        )
        let score = Score(
            division: 480, parts: [part], staves: [staff]
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
                    measureIndex: 0, tickInMeasure: 480
                ))
            default:
                if case .item = frame.cursor { } else {
                    Issue.record("Expected .item at tick \(frame.tick), got \(frame.cursor)")
                }
            }
        }
    }

    /// 6/8 → step = division / 2 (eighth ticks), 6 beats per measure.
    @Test("6/8 emits beats at the eighth-note interval, six per measure")
    func compoundTimeSigBeatStep() {
        let qDot = Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]
        )
        // Fill a 6/8 measure with three quarter notes — chord onsets
        // at ticks 0, 480, 960; missing beat ticks at 240, 720, 1200.
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 6, denominator: 8)),
            .chord(qDot), .chord(qDot), .chord(qDot),
        ])
        let staff = StaffContent(
            id: 1, measures: [Measure(voices: [voice])]
        )
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()]
            )
        )
        let score = Score(
            division: 480, parts: [part], staves: [staff]
        )

        let timeline = PlaybackTimeline(score: score)
        let ticks = timeline.frames.map(\.tick)
        #expect(ticks == [0, 240, 480, 720, 960, 1200])
    }
}
