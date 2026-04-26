#if os(macOS)
import Foundation
import SheetMusicCore

/// Hand-built sample scores for visual inspection of `ScoreView`.
enum Samples {

    // MARK: - 01 empty

    static let empty = Score(division: 480)

    // MARK: - 02 single whole note (middle C)

    static var wholeNote: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let measure = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .whole, notes: [c4])),
        ])])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [measure])])
    }

    // MARK: - 03 C major scale in quarters

    static var cMajorScale: Score {
        let pitches: [(Int, Int)] = [
            (60, 14), (62, 16), (64, 18), (65, 13),
            (67, 15), (69, 17), (71, 19), (72, 14)
        ]
        let chords: [VoiceElement] = pitches.map { p, tpc in
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: p, tpc: tpc)]))
        }
        let m1 = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ] + Array(chords.prefix(4)))])
        let m2 = Measure(voices: [Voice(elements: Array(chords.suffix(4)))])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m1, m2])])
    }

    // MARK: - 04 beamed eighths in 4/4

    static var eighthsBeamed: Score {
        let notes: [(Int, Int)] = [
            (60, 14), (62, 16), (64, 18), (65, 13),
            (67, 15), (69, 17), (71, 19), (72, 14)
        ]
        let chords: [VoiceElement] = notes.map { p, tpc in
            .chord(Chord(duration: .eighth,
                         notes: [Note(pitch: p, tpc: tpc)]))
        }
        let m = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ] + chords)])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 05 piano grand staff (2 staves)

    static var pianoGrand: Score {
        let rh = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 64, tpc: 18)])),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 67, tpc: 15)])),
            .chord(Chord(duration: .quarter,
                         notes: [Note(pitch: 72, tpc: 14)])),
        ])])
        let lh = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "F")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .half,
                         notes: [Note(pitch: 48, tpc: 14)])),
            .chord(Chord(duration: .half,
                         notes: [Note(pitch: 52, tpc: 18)])),
        ])])
        let part = Part(
            id: "P1",
            trackName: "Piano",
            instrument: Instrument(
                id: "pno", longName: "Piano", shortName: "Pno."))
        return Score(
            division: 480,
            parts: [part],
            staves: [
                StaffContent(id: 1, measures: [rh]),
                StaffContent(id: 2, measures: [lh])
            ])
    }

    // MARK: - 06 accidentals

    static var accidentals: Score {
        // C, C#, Db, D, D#, Eb, E, F — quarters
        let notes: [(Int, Int, Accidental?)] = [
            (60, 14, nil),
            (61, 21, .sharp),     // C#
            (61, 9,  .flat),      // Db
            (62, 16, nil),
            (63, 23, .sharp),     // D#
            (63, 11, .flat),      // Eb
            (64, 18, nil),
            (65, 13, nil),
        ]
        let chords: [VoiceElement] = notes.map { p, tpc, a in
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: p, tpc: tpc, accidental: a)]))
        }
        let m = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ] + chords)])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 07 rests of every duration

    static var rests: Score {
        let restElements: [VoiceElement] = [
            .rest(Rest(duration: .whole)),
            .rest(Rest(duration: .half)),
            .rest(Rest(duration: .quarter)),
            .rest(Rest(duration: .eighth)),
            .rest(Rest(duration: .sixteenth)),
            .rest(Rest(duration: .thirtySecond)),
        ]
        let m = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ] + restElements)])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 08 key signatures

    static var keySignatures: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        func m(_ k: Int) -> Measure {
            Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .keySignature(KeySignature(concertKey: k)),
                .chord(Chord(duration: .whole, notes: [c4])),
            ])])
        }
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m(3), m(-2), m(7)])])
    }

    // MARK: - 09 time signatures

    static var timeSignatures: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        func m(_ n: Int, _ d: Int) -> Measure {
            Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: n, denominator: d)),
                .chord(Chord(duration: .whole, notes: [c4])),
            ])])
        }
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1,
                measures: [m(3, 4), m(6, 8), m(12, 8)])])
    }

    // MARK: - 11 isolated flags (8ths / 16ths) up and down

    static var isolatedFlags: Score {
        // Isolated 8th / 16th / 32nd notes separated by rests so the
        // beam-group detector treats them as loners and keeps the flag
        // glyph on each note. Alternates stem-up (low notes, below
        // middle line) and stem-down (high notes).
        let smallRest = Rest(duration: .eighth)
        let elements: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            // Stem up, 8th flag
            .chord(Chord(duration: .eighth,
                         notes: [Note(pitch: 60, tpc: 14)])),
            .rest(smallRest),
            // Stem up, 16th flag
            .chord(Chord(duration: .sixteenth,
                         notes: [Note(pitch: 62, tpc: 16)])),
            .rest(smallRest),
            .rest(Rest(duration: .sixteenth)),
            // Stem down, 8th flag
            .chord(Chord(duration: .eighth,
                         notes: [Note(pitch: 72, tpc: 14)])),
            .rest(smallRest),
            // Stem down, 16th flag
            .chord(Chord(duration: .sixteenth,
                         notes: [Note(pitch: 74, tpc: 16)])),
        ]
        let m = Measure(voices: [Voice(elements: elements)])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 14 tuplets (triplet + quintuplet + septuplet)

    static var tuplets: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        // Simulate what the decoder produces for tuplet notes — it
        // scales each member's duration by (normal / actual).
        // Triplet 8th = eighth × 2/3 = Fraction(1/12).
        // Quintuplet 16th = sixteenth × 4/5 = Fraction(1/20).
        // Septuplet 16th = sixteenth × 4/7 = Fraction(1/28).
        let tripletEighth = Chord(
            duration: .fraction(Fraction(numerator: 1, denominator: 12)),
            notes: [c4])
        let quintupletSixteenth = Chord(
            duration: .fraction(Fraction(numerator: 1, denominator: 20)),
            notes: [c4])
        let septupletSixteenth = Chord(
            duration: .fraction(Fraction(numerator: 1, denominator: 28)),
            notes: [c4])
        let plain8th = Chord(duration: .eighth, notes: [c4])
        let elements: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),  // index 0
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),  // 1
            .chord(tripletEighth),   // 2  triplet start
            .chord(tripletEighth),   // 3
            .chord(tripletEighth),   // 4  triplet end
            .chord(plain8th),        // 5
            .chord(plain8th),        // 6
            .chord(quintupletSixteenth),  // 7  quintuplet start
            .chord(quintupletSixteenth),  // 8
            .chord(quintupletSixteenth),  // 9
            .chord(quintupletSixteenth),  // 10
            .chord(quintupletSixteenth),  // 11 quintuplet end
            .chord(septupletSixteenth),   // 12 septuplet start
            .chord(septupletSixteenth),   // 13
            .chord(septupletSixteenth),   // 14
            .chord(septupletSixteenth),   // 15
            .chord(septupletSixteenth),   // 16
            .chord(septupletSixteenth),   // 17
            .chord(septupletSixteenth),   // 18 septuplet end
        ]
        let tuplets = [
            Tuplet(normalNotes: 2, actualNotes: 3,
                   startIndex: 2, endIndex: 4),
            Tuplet(normalNotes: 4, actualNotes: 5,
                   startIndex: 7, endIndex: 11),
            Tuplet(normalNotes: 4, actualNotes: 7,
                   startIndex: 12, endIndex: 18),
        ]
        let m = Measure(voices: [
            Voice(elements: elements, tuplets: tuplets),
        ])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 15 non-beamed tuplet (quarter-note triplet with bracket)

    static var tupletBracket: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        // Triplet quarter = quarter × 2/3 = Fraction(1/6)
        let tripletQuarter = Chord(
            duration: .fraction(Fraction(numerator: 1, denominator: 6)),
            notes: [c4])
        let halfNote = Chord(duration: .half, notes: [c4])
        let elements: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),  // 0
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                                                  // 1
            // 3 triplet quarters → should get a bracket + "3"
            .chord(tripletQuarter),               // 2
            .chord(tripletQuarter),               // 3
            .chord(tripletQuarter),               // 4
            .chord(halfNote),                     // 5
        ]
        let tuplets = [
            Tuplet(normalNotes: 2, actualNotes: 3,
                   startIndex: 2, endIndex: 4),
        ]
        let m = Measure(voices: [
            Voice(elements: elements, tuplets: tuplets),
        ])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 13 mixed-duration beam groups

    static var mixedBeams: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let e4 = Note(pitch: 64, tpc: 18)
        let eighth = Chord(duration: .eighth, notes: [c4])
        let sixteenth = Chord(duration: .sixteenth, notes: [e4])
        let dotted8th = Chord(
            duration: NoteDuration.eighth.dotted(1), notes: [c4])
        let elements: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            // 8th + 16th + 16th (primary beam spans all; secondary beam
            // only between the two 16ths)
            .chord(eighth), .chord(sixteenth), .chord(sixteenth),
            // 16th + 16th + 8th (mirror: secondary only on first pair)
            .chord(sixteenth), .chord(sixteenth), .chord(eighth),
            // dotted 8th + 16th (primary beam + partial stub on 16th)
            .chord(dotted8th), .chord(sixteenth),
            // 16th + dotted 8th (mirror: partial stub on leading 16th)
            .chord(sixteenth), .chord(dotted8th),
        ]
        let m = Measure(voices: [Voice(elements: elements)])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 16 beat-boundary break with mixed durations

    static var beatBoundaryBreak: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let eighth = Chord(duration: .eighth, notes: [c4])
        let dotted8th = Chord(
            duration: NoteDuration.eighth.dotted(1), notes: [c4])
        let sixteenth = Chord(
            duration: .sixteenth, notes: [Note(pitch: 64, tpc: 18)])
        let elements: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            // dotted8th + 16th | 8th + 8th  → should split (2+2)
            .chord(dotted8th), .chord(sixteenth),
            .chord(eighth), .chord(eighth),
            // 8th + 8th + 8th + 8th  → should merge (group of 4)
            .chord(eighth), .chord(eighth),
            .chord(eighth), .chord(eighth),
        ]
        let m = Measure(voices: [Voice(elements: elements)])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 21 rest/note overlap reproduction (user-reported)

    /// Reproduces the user's reported alignment bug.  Staff 1 carries
    /// many 16ths that include ticks not present in staff 2; staff 2
    /// has a sparser rhythm whose total voice-weight is SMALLER than
    /// staff 1's.  With naive max-of-voice-fractions spacing, staff
    /// 2's inflated fractions would push tick 1200's x to the right
    /// of tick 1320's x — causing staff 1's rest at 1320 to render
    /// behind its own note at 1200.  After aggregated-weight spacing,
    /// every tick is monotonic across every voice.
    static var restNoteOverlapRepro: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let s1: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(Rest(duration: .half)),
            .rest(Rest(duration: .sixteenth)),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .rest(Rest(duration: .sixteenth)),
            .rest(Rest(duration: .sixteenth)),
            .rest(Rest(duration: .sixteenth)),
            .rest(Rest(duration: .sixteenth)),
            .rest(Rest(duration: .sixteenth)),  // pad to full 1920
        ]
        let s2: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .rest(Rest(duration: .half)),
            .rest(Rest(duration: .sixteenth)),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .rest(Rest(duration: .eighth)),
            .chord(Chord(
                duration: NoteDuration.eighth.dotted(1),
                notes: [c4])),
            .rest(Rest(duration: .sixteenth)),
        ]
        let part = Part(
            id: "P1",
            trackName: "Duo",
            instrument: Instrument(
                id: "synth",
                longName: "Duo", shortName: "D."))
        return Score(
            division: 480,
            parts: [part],
            staves: [
                StaffContent(
                    id: 1, measures: [Measure(voices: [Voice(elements: s1)])]),
                StaffContent(
                    id: 2, measures: [Measure(voices: [Voice(elements: s2)])]),
            ])
    }

    // MARK: - 20 multi-voice whole-rest placement

    /// Voice 0 runs four quarter notes; voice 1 holds a whole rest.
    /// A single-voice whole rest is conventionally centered in the
    /// measure, but in a multi-voice measure that centering would
    /// drop the rest exactly on top of one of voice 0's notes.  The
    /// whole rest therefore anchors to its tick (0) and uses the
    /// voice's y-offset to stay clear of the melody.
    static var multiVoiceWholeRest: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let m = Measure(voices: [
            Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [c4])),
                .chord(Chord(duration: .quarter, notes: [c4])),
                .chord(Chord(duration: .quarter, notes: [c4])),
                .chord(Chord(duration: .quarter, notes: [c4])),
            ]),
            Voice(elements: [
                .rest(Rest(duration: .whole)),
            ]),
        ])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 19 two-voice rest / note alignment (diagnostic)

    /// Two voices in one staff, with voice 0 carrying a busy 16th-note
    /// pattern and voice 1 alternating kick notes and rests. Every
    /// voice-1 rest shares a tick with a voice-0 note; the two must
    /// coexist without visual overlap. This mirrors MuseScore's
    /// "drum set" notation where melody (voice 0) and rhythm (voice 1)
    /// are written on the same staff.
    static var twoVoiceRestNote: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let b3 = Note(pitch: 59, tpc: 12)
        let c3 = Note(pitch: 48, tpc: 14)
        let v0: [VoiceElement] = [
            .chord(Chord(duration: .eighth, notes: [c4])),
            .chord(Chord(duration: .sixteenth, notes: [b3])),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .chord(Chord(duration: .sixteenth, notes: [b3])),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .chord(Chord(duration: .eighth, notes: [c4])),
            .chord(Chord(duration: .sixteenth, notes: [b3])),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .chord(Chord(duration: .sixteenth, notes: [b3])),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .chord(Chord(duration: .quarter, notes: [c4])),
        ]
        let v1: [VoiceElement] = [
            .chord(Chord(duration: .eighth, notes: [c3])),
            .rest(Rest(duration: .eighth)),
            .rest(Rest(duration: .eighth)),
            .chord(Chord(duration: .eighth, notes: [c3])),
            .rest(Rest(duration: .quarter)),
            .chord(Chord(duration: .quarter, notes: [c3])),
        ]
        let leadingV0: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ] + v0
        let m = Measure(voices: [
            Voice(elements: leadingV0),
            Voice(elements: v1),
        ])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 18 cross-staff alignment (shared tick columns)

    /// Two staves with different rhythms but a shared duration envelope.
    /// Staff 1 plays `8th + 16th + 16th` every beat; staff 2 plays
    /// `dotted 8th + 16th` every beat.  The 16ths at the end of each
    /// beat (tick 360, 840, 1320, 1800) must line up vertically across
    /// the two staves — every notehead in staff 2 shares an x with the
    /// matching notehead in staff 1.
    static var multiStaffAlignment: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let d4 = Note(pitch: 62, tpc: 16)
        let e4 = Note(pitch: 64, tpc: 18)
        let c3 = Note(pitch: 48, tpc: 14)
        let e3 = Note(pitch: 52, tpc: 18)

        // Staff 1 — 8th + 16th + 16th per beat ×4.
        var rhElems: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ]
        for _ in 0..<4 {
            rhElems.append(.chord(Chord(duration: .eighth, notes: [c4])))
            rhElems.append(.chord(Chord(duration: .sixteenth, notes: [d4])))
            rhElems.append(.chord(Chord(duration: .sixteenth, notes: [e4])))
        }

        // Staff 2 — dotted 8th + 16th per beat ×4.
        var lhElems: [VoiceElement] = [
            .clef(Clef(concertClefType: "F")),
        ]
        for _ in 0..<4 {
            lhElems.append(.chord(Chord(
                duration: NoteDuration.eighth.dotted(1),
                notes: [c3])))
            lhElems.append(.chord(Chord(
                duration: .sixteenth, notes: [e3])))
        }

        let rh = Measure(voices: [Voice(elements: rhElems)])
        let lh = Measure(voices: [Voice(elements: lhElems)])
        let part = Part(
            id: "P1",
            trackName: "Piano",
            instrument: Instrument(
                id: "pno", longName: "Piano", shortName: "Pno."))
        return Score(
            division: 480,
            parts: [part],
            staves: [
                StaffContent(id: 1, measures: [rh]),
                StaffContent(id: 2, measures: [lh]),
            ])
    }

    // MARK: - 17 beat boundary with 16ths (secondary-beam rule)

    static var beatBoundary16ths: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let e4 = Note(pitch: 64, tpc: 18)
        let c16 = Chord(duration: .sixteenth, notes: [c4])
        let e16 = Chord(duration: .sixteenth, notes: [e4])

        // Measure 1 — 16 consecutive 16ths.  Secondary beams (level 2
        // or deeper) break at every beat boundary even when both sides
        // are uniform at the same level, so the bar renders as
        // 4+4+4+4 rather than one run of 16 or two half-bar runs of 8.
        let m1 = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(c16), .chord(c16), .chord(c16), .chord(c16),
            .chord(c16), .chord(c16), .chord(c16), .chord(c16),
            .chord(c16), .chord(c16), .chord(c16), .chord(c16),
            .chord(c16), .chord(c16), .chord(c16), .chord(c16),
        ])])

        // Measure 2 — sparse 16th figure spanning beats 3 and 4.
        // The two consecutive 16th notes that straddle the beat
        // boundary must NOT be beamed together, even though they are
        // the only unbroken pair in that stretch.  Each renders as a
        // lone flagged note; only the closing 16+16 inside beat 4
        // stays beamed.
        let m2 = Measure(voices: [Voice(elements: [
            .rest(Rest(duration: .half)),
            .rest(Rest(duration: .sixteenth)),
            .chord(c16),
            .rest(Rest(duration: .sixteenth)),
            .chord(c16),
            .chord(e16),
            .rest(Rest(duration: .sixteenth)),
            .chord(c16),
            .chord(e16),
        ])])

        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m1, m2])])
    }

    // MARK: - 12 dotted durations (single + double dot)

    static var dottedDurations: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let elements: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            // dotted half (3 beats)
            .chord(Chord(
                duration: NoteDuration.half.dotted(1),
                notes: [c4])),
            .rest(Rest(duration: NoteDuration.quarter)),
            // dotted quarter
            .chord(Chord(
                duration: NoteDuration.quarter.dotted(1),
                notes: [c4])),
            // dotted 8th
            .chord(Chord(
                duration: NoteDuration.eighth.dotted(1),
                notes: [c4])),
            .rest(Rest(duration: NoteDuration.sixteenth)),
            // double-dotted quarter
            .chord(Chord(
                duration: NoteDuration.quarter.dotted(2),
                notes: [c4])),
            // dotted rest
            .rest(Rest(duration: NoteDuration.quarter.dotted(1))),
        ]
        let m = Measure(voices: [Voice(elements: elements)])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - 10 dynamics + tempo

    static var dynamicsTempo: Score {
        let c4 = Note(pitch: 60, tpc: 14)
        let m = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .tempo(Tempo(beatsPerSecond: 2.0)),   // 120 BPM
            .dynamic(Dynamic(subtype: "mf", velocity: 80)),
            .chord(Chord(duration: .quarter, notes: [c4])),
            .chord(Chord(duration: .quarter, notes: [c4])),
            .dynamic(Dynamic(subtype: "f", velocity: 100)),
            .chord(Chord(duration: .half, notes: [c4])),
        ])])
        return Score(
            division: 480,
            parts: [treblePart()],
            staves: [StaffContent(id: 1, measures: [m])])
    }

    // MARK: - helpers

    private static func treblePart() -> Part {
        Part(
            id: "P1",
            trackName: nil,
            instrument: Instrument(
                id: "synth", longName: "Treble", shortName: "Tr."))
    }
}
#endif
