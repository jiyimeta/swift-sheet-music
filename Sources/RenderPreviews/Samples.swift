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
