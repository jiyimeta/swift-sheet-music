import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterVoicingTests {
    private func nOn(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: 80))
    }

    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    @Test func simultaneousOnSimultaneousOffMakesOneChord() {
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [nOn(0, 60), nOn(0, 64), nOff(480, 60), nOff(480, 64)],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        #expect(voice.elements.count == 1)
        if case let .chord(c) = voice.elements[0] {
            #expect(c.notes.count == 2)
        }
    }

    @Test func staggeredOffMakesTieToContinuingPitch() {
        // C4 and E4 on at tick 0; E4 off at 240, C4 off at 480.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [nOn(0, 60), nOn(0, 64), nOff(240, 64), nOff(480, 60)],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        #expect(voice.elements.count == 2)
        // First chord: both pitches; C4 (pitch 60) should carry forward via tieForward.
        if case let .chord(c0) = voice.elements[0] {
            #expect(c0.notes.count == 2)
            let c = c0.notes.first(where: { $0.pitch == 60 })
            #expect(c?.tieForward == 1)
        }
        // Second chord: only C4, with tieBack.
        if case let .chord(c1) = voice.elements[1] {
            #expect(c1.notes.count == 1)
            #expect(c1.notes.first?.pitch == 60)
            #expect(c1.notes.first?.tieBack == 1)
        }
    }

    @Test func gapBetweenNotesProducesEmptyChordRest() {
        // Note ends at 240, next note starts at 360 → gap of 120 ticks
        // emits an empty-chord rest.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [nOn(0, 60), nOff(240, 60), nOn(360, 62), nOff(480, 62)],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        // Expect: chord (60), rest, chord (62)
        #expect(voice.elements.count == 3)
        if case let .chord(c1) = voice.elements[1] {
            #expect(c1.notes.isEmpty)
        }
    }

    @Test func tupletIndicesSurviveSustainedNoteThroughVoicing() {
        // Beat 0..480 has a triplet on pitch 60 (onsets at 0, 160, 320).
        // A sustained pitch 67 starts at tick 0 and ends at tick 240
        // — mid-triplet. The voicing pass adds an extra grid step at
        // tick 240, so the rebuilt elements list has more entries than
        // the quantizer's. Tuplet indices must still point at the
        // triplet members in the rebuilt list.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                // Triplet on pitch 60.
                TimedMidiEvent(
                    tick: 0,
                    event: .noteOn(channel: 0, pitch: 60, velocity: 80)
                ),
                TimedMidiEvent(
                    tick: 160,
                    event: .noteOff(channel: 0, pitch: 60, velocity: 0)
                ),
                TimedMidiEvent(
                    tick: 160,
                    event: .noteOn(channel: 0, pitch: 62, velocity: 80)
                ),
                TimedMidiEvent(
                    tick: 320,
                    event: .noteOff(channel: 0, pitch: 62, velocity: 0)
                ),
                TimedMidiEvent(
                    tick: 320,
                    event: .noteOn(channel: 0, pitch: 64, velocity: 80)
                ),
                TimedMidiEvent(
                    tick: 480,
                    event: .noteOff(channel: 0, pitch: 64, velocity: 0)
                ),
                // Sustained pitch 67, ends mid-triplet at tick 240.
                TimedMidiEvent(
                    tick: 0,
                    event: .noteOn(channel: 0, pitch: 67, velocity: 80)
                ),
                TimedMidiEvent(
                    tick: 240,
                    event: .noteOff(channel: 0, pitch: 67, velocity: 0)
                ),
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(
            measure: measure, division: 480, options: .init()
        )
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480
        )
        #expect(voice.tuplets.count == 1)
        let tuplet = voice.tuplets[0]
        // The chords at tuplet.startIndex...tuplet.endIndex must all
        // contain pitch 60/62/64 (the triplet members), not the
        // sustained-note rest chord at tick 240.
        let tripletPitches: [[Int]] = (tuplet.startIndex ... tuplet.endIndex).map { i in
            if case let .chord(c) = voice.elements[i] {
                return c.notes.map(\.pitch)
            }
            return []
        }
        // Each tuplet member should contain at least one of {60, 62, 64}.
        let tripletPitchesFlat = Set(tripletPitches.flatMap { $0 })
        #expect(tripletPitchesFlat.contains(60))
        #expect(tripletPitchesFlat.contains(62))
        #expect(tripletPitchesFlat.contains(64))
    }

    @Test func crossBarNoteEmitsTieAcrossBar() {
        // Two adjacent measures of 4/4 (1920 ticks each). A note starts
        // at tick 0 (measure 0), ends at tick 3000 (measure 1, partway).
        let crossing = CarriedNote(
            pitch: 60, channel: 0, sourceMeasureIndex: 0,
            noteOnTick: 0, noteOffTick: 3000
        )
        let m1 = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 1920, event: .endOfTrack),
            ],
            carryIns: [],
            carryOuts: [crossing]
        )
        let m2 = ImportMeasure(
            startTick: 1920, endTick: 3840, measureIndex: 1,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                TimedMidiEvent(tick: 3000, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
            ],
            carryIns: [crossing],
            carryOuts: []
        )

        let v1 = MidiImporter.voice(
            quantized: MidiImporter.quantize(measure: m1, division: 480, options: .init()),
            measure: m1, division: 480
        )
        let v2 = MidiImporter.voice(
            quantized: MidiImporter.quantize(measure: m2, division: 480, options: .init()),
            measure: m2, division: 480
        )

        // Last chord of m1: tieForward set on pitch 60.
        guard let lastM1 = v1.elements.last else {
            Issue.record("expected chord at end of m1")
            return
        }
        if case let .chord(c) = lastM1 {
            let n = c.notes.first(where: { $0.pitch == 60 })
            #expect(n != nil)
            #expect(n?.tieForward == 1)
        } else {
            Issue.record("expected chord at end of m1")
        }
        // First chord of m2: tieBack set on pitch 60.
        guard let firstM2 = v2.elements.first else {
            Issue.record("expected chord at start of m2")
            return
        }
        if case let .chord(c) = firstM2 {
            let n = c.notes.first(where: { $0.pitch == 60 })
            #expect(n != nil)
            #expect(n?.tieBack == 1)
        } else {
            Issue.record("expected chord at start of m2")
        }
    }

    @Test func tpcMatchesMuseScoreLineOfFifthsForCMajor() {
        // No key context (= C major). Naturals on the line of fifths:
        // F=13, C=14, G=15, D=16, A=17, E=18, B=19. Black keys default
        // to sharp spellings: C#=21, D#=23, F#=20, G#=22, A#=24.
        #expect(MidiImporter.tpc(forMidiPitch: 60) == 14) // C4
        #expect(MidiImporter.tpc(forMidiPitch: 62) == 16) // D4
        #expect(MidiImporter.tpc(forMidiPitch: 64) == 18) // E4
        #expect(MidiImporter.tpc(forMidiPitch: 65) == 13) // F4
        #expect(MidiImporter.tpc(forMidiPitch: 67) == 15) // G4
        #expect(MidiImporter.tpc(forMidiPitch: 69) == 17) // A4
        #expect(MidiImporter.tpc(forMidiPitch: 71) == 19) // B4
        #expect(MidiImporter.tpc(forMidiPitch: 61) == 21) // C#4
        #expect(MidiImporter.tpc(forMidiPitch: 66) == 20) // F#4
        // Octave-invariant: same pitch class → same TPC.
        #expect(MidiImporter.tpc(forMidiPitch: 48) == 14) // C3
        #expect(MidiImporter.tpc(forMidiPitch: 72) == 14) // C5
    }

    @Test func tpcUsesFlatSpellingsInFlatKeys() {
        // Bb major (concertKey = -2). Black keys take flat spellings:
        // Db=7, Eb=11, Gb=6, Ab=8, Bb=10. Naturals are unchanged.
        #expect(MidiImporter.tpc(forMidiPitch: 61, concertKey: -2) == 7) // Db
        #expect(MidiImporter.tpc(forMidiPitch: 63, concertKey: -2) == 11) // Eb
        #expect(MidiImporter.tpc(forMidiPitch: 66, concertKey: -2) == 6) // Gb
        #expect(MidiImporter.tpc(forMidiPitch: 68, concertKey: -2) == 8) // Ab
        #expect(MidiImporter.tpc(forMidiPitch: 70, concertKey: -2) == 10) // Bb
        // White keys still use natural TPC (a chromatic accidental
        // would be rendered as a natural sign in a sharp key, etc.):
        #expect(MidiImporter.tpc(forMidiPitch: 60, concertKey: -2) == 14) // C
        #expect(MidiImporter.tpc(forMidiPitch: 65, concertKey: -2) == 13) // F
    }

    @Test func draftedOnsetsSnapToBinaryGridAndProduceStandardDurations() {
        // DAW-style drift: notes intended at 0 / 480 / 960 / 1440
        // arrive a few ticks early or late. Voicing must snap them to
        // the 16th grid so chord durations come out as standard binary
        // values (`.quarter` here) rather than `.fraction(...)`.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(2, 60), nOff(478, 60),
                nOn(478, 62), nOff(963, 62),
                nOn(963, 64), nOff(1437, 64),
                nOn(1437, 65), nOff(1922, 65),
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        let durations = voice.elements.compactMap { e -> NoteDuration? in
            if case let .chord(c) = e { return c.duration }
            return nil
        }
        #expect(durations == [.quarter, .quarter, .quarter, .quarter])
    }

    @Test func dottedEighthAndSixteenthAndHalfPreserved() {
        // Mix of half (960) + dotted eighth (360) + sixteenth (120)
        // + quarter (480) = 1920. Slight DAW-style drift on each
        // boundary — voicing must snap to grid and emit the right
        // durations: any `.fraction` here must be a standard
        // dotted-form (i.e. decomposable to base+dots), not an
        // irreducible drift.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(2, 60), nOff(958, 60), // half
                nOn(958, 62), nOff(1322, 62), // dotted eighth
                nOn(1322, 64), nOff(1438, 64), // sixteenth
                nOn(1438, 65), nOff(1920, 65), // quarter
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        let durations = voice.elements.compactMap { e -> NoteDuration? in
            if case let .chord(c) = e { return c.duration }
            return nil
        }
        // The dotted eighth is encoded as `.fraction(3/16)`; the
        // others as their direct enum cases.
        let expectedDottedEighth = NoteDuration.fraction(Fraction(numerator: 3, denominator: 16))
        #expect(durations.contains(.half))
        #expect(durations.contains(.sixteenth))
        #expect(durations.contains(.quarter))
        #expect(durations.contains(expectedDottedEighth))
    }

    @Test func chordDurationsSumExactlyToMeasureLength() {
        // Imported voicing must emit chord durations whose tick-sum
        // equals the measure length exactly. Otherwise PlaybackTimeline
        // / MetronomeBeat's spineTick drifts and metronome events can
        // land out of order, tripping MidiWriter's sorted-by-tick
        // precondition.
        //
        // Build a measure where the gap between events is 720 ticks
        // (dotted quarter) — a value `nearestDuration` would round to
        // `.half` (960). With `exactDuration` it must be tick-exact.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(0, 60), nOff(720, 60), // dotted quarter
                nOn(720, 62), nOff(1920, 62), // dotted half
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        let totalTicks = voice.elements.reduce(0) { acc, el in
            if case let .chord(c) = el {
                return acc + c.duration.ticks(division: 480)
            }
            return acc
        }
        #expect(totalTicks == 1920)
    }

    @Test func tpcUsesSharpSpellingsInSharpKeys() {
        // D major (concertKey = +2). Black keys take sharp spellings.
        #expect(MidiImporter.tpc(forMidiPitch: 61, concertKey: 2) == 21) // C#
        #expect(MidiImporter.tpc(forMidiPitch: 63, concertKey: 2) == 23) // D#
        #expect(MidiImporter.tpc(forMidiPitch: 66, concertKey: 2) == 20) // F#
        #expect(MidiImporter.tpc(forMidiPitch: 68, concertKey: 2) == 22) // G#
        #expect(MidiImporter.tpc(forMidiPitch: 70, concertKey: 2) == 24) // A#
    }

    @Test func voicedNotesCarryCorrectTpcNotZero() {
        // Regression test: previously every imported note had tpc=0,
        // which is off the line of fifths and renders as C
        // regardless of MIDI pitch. After the fix, each pitch class
        // gets its natural-or-sharp TPC.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(0, 60), nOff(480, 60), // C
                nOn(480, 64), nOff(960, 64), // E
                nOn(960, 67), nOff(1440, 67), // G
                nOn(1440, 71), nOff(1920, 71), // B
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        let tpcs = voice.elements.compactMap { e -> Int? in
            if case let .chord(c) = e, let first = c.notes.first {
                return first.tpc
            }
            return nil
        }
        #expect(tpcs == [14, 18, 15, 19]) // C, E, G, B
    }
}
