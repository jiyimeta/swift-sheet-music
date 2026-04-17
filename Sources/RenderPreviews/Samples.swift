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
