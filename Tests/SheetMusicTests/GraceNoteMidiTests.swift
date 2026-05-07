@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite("MidiRenderer.playbackTicks")
struct GracePlaybackTicksTests {
    private let division = 480 // PPQ used by every other MIDI test

    @Test("acciaccatura → 1/32 of a quarter note (= division/8)")
    func acciaccatura() {
        let g = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [])
        #expect(MidiRenderer.playbackTicks(
            for: g, mainTicks: division, division: division
        ) == division / 8)
    }

    @Test("appoggiatura → half of mainTicks")
    func appoggiatura() {
        let g = GraceChord(graceType: .appoggiatura, duration: .quarter, notes: [])
        #expect(MidiRenderer.playbackTicks(
            for: g, mainTicks: division, division: division
        ) == division / 2)
    }

    @Test("grace4 / grace16 / grace32 use fixed durations")
    func fixedFractions() {
        let mk = { (gt: GraceType) in
            GraceChord(graceType: gt, duration: .eighth, notes: [])
        }
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace4), mainTicks: division, division: division
        ) == division)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace16), mainTicks: division, division: division
        ) == division / 4)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace32), mainTicks: division, division: division
        ) == division / 8)
    }

    @Test("grace8/16/32after use 1/8, 1/16, 1/32 of a quarter")
    func afterFixed() {
        let mk = { (gt: GraceType) in
            GraceChord(graceType: gt, duration: .eighth, notes: [])
        }
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace8after), mainTicks: division, division: division
        ) == division / 2)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace16after), mainTicks: division, division: division
        ) == division / 4)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace32after), mainTicks: division, division: division
        ) == division / 8)
    }
}

@Suite("MidiRenderer.totalSteal")
struct GraceTotalStealTests {
    private let division = 480

    @Test("totalStealFromPrev = sum of acciaccatura ticks only")
    func stealPrev() {
        let g1 = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [])
        let g2 = GraceChord(graceType: .grace16, duration: .sixteenth, notes: [])
        #expect(MidiRenderer.totalStealFromPrev([g1, g2], division: division)
            == division / 8)
    }

    @Test("totalStealFromMainHead = sum of non-acciaccatura before-grace ticks")
    func stealHead() {
        let g1 = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [])
        let g2 = GraceChord(graceType: .grace16, duration: .sixteenth, notes: [])
        #expect(MidiRenderer.totalStealFromMainHead(
            [g1, g2], mainTicks: division, division: division
        ) == division / 4)
    }

    @Test("Head steal capped at mainTicks/2 when graces overflow")
    func headCap() {
        // Three grace4 → 3 * 480 = 1440, but main is 480 → cap to 240.
        let four = (0 ..< 3).map { _ in
            GraceChord(graceType: .grace4, duration: .quarter, notes: [])
        }
        #expect(MidiRenderer.totalStealFromMainHead(
            four, mainTicks: division, division: division
        ) == division / 2)
    }

    @Test("totalStealFromMainTail sums after-grace ticks (capped at half)")
    func stealTail() {
        let g = GraceChord(graceType: .grace8after, duration: .eighth, notes: [])
        #expect(MidiRenderer.totalStealFromMainTail(
            [g], mainTicks: division, division: division
        ) == division / 2)
        let many = (0 ..< 4).map { _ in g }
        #expect(MidiRenderer.totalStealFromMainTail(
            many, mainTicks: division, division: division
        ) == division / 2) // capped
    }
}

@Suite("Grace MIDI integration")
struct GraceMidiIntegrationTests {
    /// Build a single-staff, single-voice score with `chords` as
    /// the body of measure 0. Returns the rendered events and the PPQ.
    private func render(_ chords: [Chord]) -> (events: [TimedMidiEvent], ppq: Int) {
        let division = 480
        let measure = Measure(voices: [Voice(elements: chords.map { .chord($0) })])
        let staff = Staff(measures: [measure])
        let instrument = Instrument(id: "piano", articulations: [InstrumentArticulation()])
        let part = Part(id: "P1", instrument: instrument, staves: [staff])
        let score = Score(division: division, parts: [part])
        // swiftlint:disable:next force_try
        let file = try! MidiRenderer.render(score: score)
        return (file.tracks.flatMap(\.events), Int(file.division))
    }

    private func note(_ pitch: Int) -> Note { Note(pitch: pitch, tpc: 14) }

    @Test("acciaccatura: prev chord noteOff is pulled in by grace ticks")
    func acciaccaturaStealsPrev() {
        let prev = Chord(duration: .quarter, notes: ChordNotes([note(60)]))
        let main = Chord(
            duration: .quarter,
            notes: ChordNotes([note(64)]),
            graceNotesBefore: [GraceChord(
                graceType: .acciaccatura, duration: .eighth,
                notes: ChordNotes([note(62)])
            )]
        )
        let (events, ppq) = render([prev, main])
        let prevOff = events.first { e in
            if case let .noteOff(_, p, _) = e.event, p == 60 { return true }
            return false
        }
        // prev quarter starts at 0 with gate ≈ 100% → off ~ ppq-1.
        // Acciaccatura steals ppq/8.
        #expect(prevOff?.tick == ppq - 1 - ppq / 8)

        // Grace note-on lands BEFORE main onset (= ppq).
        let graceOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 62 { return true }
            return false
        }
        #expect(graceOn?.tick == ppq - ppq / 8)

        // Main onset still at ppq (acciaccatura doesn't shift main).
        let mainOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 64 { return true }
            return false
        }
        #expect(mainOn?.tick == ppq)
    }

    @Test("appoggiatura: main onset shifts forward by grace ticks")
    func appoggiaturaStealsMain() {
        let main = Chord(
            duration: .quarter,
            notes: ChordNotes([note(60)]),
            graceNotesBefore: [GraceChord(
                graceType: .appoggiatura, duration: .eighth,
                notes: ChordNotes([note(62)])
            )]
        )
        let (events, ppq) = render([main])
        let graceOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 62 { return true }; return false
        }
        let mainOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 60 { return true }; return false
        }
        #expect(graceOn?.tick == 0)
        #expect(mainOn?.tick == ppq / 2)
    }

    @Test("grace8after: emitted after main, main tail shortened")
    func afterGrace() {
        let main = Chord(
            duration: .quarter,
            notes: ChordNotes([note(60)]),
            graceNotesAfter: [GraceChord(
                graceType: .grace8after, duration: .eighth,
                notes: ChordNotes([note(62)])
            )]
        )
        let (events, ppq) = render([main])
        let mainOff = events.first { e in
            if case let .noteOff(_, p, _) = e.event, p == 60 { return true }; return false
        }
        let graceOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 62 { return true }; return false
        }
        // Main quarter = ppq ticks, tail steal = ppq/2 → main plays
        // for ppq/2; off-tick = mainOnset + playedTicks - 1 = ppq/2 - 1.
        #expect(mainOff?.tick == ppq / 2 - 1)
        #expect(graceOn?.tick == ppq / 2)
    }

    @Test("acciaccatura on first chord: steal-from-prev gracefully clamps")
    func acciaccaturaNoPrev() {
        // No previous chord → graceTick would be negative; renderer
        // must clamp and still emit grace + main without crashing.
        let main = Chord(
            duration: .quarter,
            notes: ChordNotes([note(60)]),
            graceNotesBefore: [GraceChord(
                graceType: .acciaccatura, duration: .eighth,
                notes: ChordNotes([note(62)])
            )]
        )
        let (events, _) = render([main])
        let graceOn = events.first { e in
            if case let .noteOn(_, p, _) = e.event, p == 62 { return true }; return false
        }
        #expect(graceOn?.tick == 0) // clamped to ≥ 0
    }
}
