@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Grace notes as MuseScore 4's playback places them, and the MIDI file's own rule left as it was.
@Suite("Grace notes in performance")
struct GracePerformanceTimingTests {
    private let division = 480

    private func note(_ pitch: Int) -> Note {
        Note(pitch: pitch, tpc: 14)
    }

    private func grace(_ type: GraceType, _ duration: NoteDuration, _ pitch: Int = 62) -> GraceChord {
        GraceChord(graceType: type, duration: duration, notes: ChordNotes([note(pitch)]))
    }

    private func score(_ elements: [VoiceElement]) -> Score {
        let staff = Staff(measures: [Measure(voices: [Voice(elements: elements)])])
        let part = Part(
            id: "P1", instrument: Instrument(id: "piano", articulations: [InstrumentArticulation()]), staves: [staff],
        )
        return Score(division: division, parts: [part])
    }

    private func onsets(_ file: MidiFile, pitch: Int) -> [Int] {
        file.tracks.flatMap(\.events).compactMap { event in
            if case let .noteOn(_, sounding, _) = event.event, sounding == pitch { event.tick } else { nil }
        }
    }

    private func release(_ file: MidiFile, pitch: Int) -> Int? {
        file.tracks.flatMap(\.events).first { event in
            if case let .noteOff(_, sounding, _) = event.event { sounding == pitch } else { false }
        }?.tick
    }

    private var slashedBeforeSecondQuarter: Score {
        score([
            .chord(Chord(duration: .quarter, notes: ChordNotes([note(60)]))),
            .chord(Chord(
                duration: .quarter, notes: ChordNotes([note(64)]), graceNotesBefore: [grace(.acciaccatura, .eighth)],
            )),
        ])
    }

    @Test("a slashed grace starts on the beat, delays its note by a 64th and leaves the note before it whole")
    func slashedGraceIsOnTheBeat() throws {
        let file = try MidiRenderer.renderForPlayback(score: slashedBeforeSecondQuarter)
        #expect(onsets(file, pitch: 62) == [480])
        #expect(onsets(file, pitch: 64) == [510])
        #expect(release(file, pitch: 60) == 479)
        #expect(release(file, pitch: 62) == 509)
        #expect(release(file, pitch: 64) == 959)
    }

    @Test("an audio export through the sequencer sounds as live playback does")
    func performanceRenderWithoutChokes() throws {
        let file = try MidiRenderer.render(score: slashedBeforeSecondQuarter, emittingChokes: false)
        #expect(onsets(file, pitch: 62) == [480])
    }

    @Test("a MIDI file keeps the slashed grace before the beat")
    func fileKeepsTheExportRule() throws {
        let file = try MidiRenderer.render(score: slashedBeforeSecondQuarter)
        #expect(onsets(file, pitch: 62) == [420])
        #expect(onsets(file, pitch: 64) == [480])
    }

    @Test("the first note of a score can carry a slashed grace")
    func firstNote() throws {
        let file = try MidiRenderer.renderForPlayback(score: score([
            .chord(Chord(
                duration: .quarter, notes: ChordNotes([note(64)]), graceNotesBefore: [grace(.acciaccatura, .eighth)],
            )),
        ]))
        #expect(onsets(file, pitch: 62) == [0])
        #expect(onsets(file, pitch: 64) == [30])
    }

    @Test("a lone unslashed grace takes its written length, up to half of the note", arguments: [
        (NoteDuration.half, GraceType.grace16, NoteDuration.sixteenth, 120),
        (.quarter, .appoggiatura, .eighth, 240),
        (.half, .appoggiatura, .eighth, 240),
        (.eighth, .grace4, .quarter, 120),
    ])
    func leaningGrace(main: NoteDuration, type: GraceType, written: NoteDuration, delay: Int) throws {
        let file = try MidiRenderer.renderForPlayback(score: score([
            .chord(Chord(duration: main, notes: ChordNotes([note(64)]), graceNotesBefore: [grace(type, written)])),
        ]))
        #expect(onsets(file, pitch: 62) == [0])
        #expect(onsets(file, pitch: 64) == [delay])
    }

    @Test("in a compound meter a lone unslashed grace may take two thirds")
    func compoundMeter() throws {
        let chord = Chord(
            duration: .quarter.dotted(1), notes: ChordNotes([note(64)]), graceNotesBefore: [grace(.grace4, .half)],
        )
        let simple = try MidiRenderer.renderForPlayback(score: score([.chord(chord)]))
        let compound = try MidiRenderer.renderForPlayback(score: score([
            .timeSignature(TimeSignature(numerator: 6, denominator: 8)), .chord(chord),
        ]))
        #expect(onsets(simple, pitch: 64) == [360])
        #expect(onsets(compound, pitch: 64) == [480])
    }

    @Test("a run of graces gets a 64th each, in its written proportions, and never more than half of the note")
    func run() throws {
        let run = [
            grace(.grace16, .sixteenth, 60), grace(.grace16, .sixteenth, 62), grace(.grace16, .sixteenth, 63),
        ]
        let quarter = try MidiRenderer.renderForPlayback(score: score([
            .chord(Chord(duration: .quarter, notes: ChordNotes([note(64)]), graceNotesBefore: run)),
        ]))
        #expect([60, 62, 63, 64].flatMap { onsets(quarter, pitch: $0) } == [0, 30, 60, 90])
        let short = try MidiRenderer.renderForPlayback(score: score([
            .chord(Chord(duration: .sixteenth, notes: ChordNotes([note(64)]), graceNotesBefore: run)),
        ]))
        #expect([60, 62, 63, 64].flatMap { onsets(short, pitch: $0) } == [0, 20, 40, 60])
    }

    @Test("a grace after the note ends with it, and shares it with one before")
    func after() throws {
        let file = try MidiRenderer.renderForPlayback(score: score([
            .chord(Chord(
                duration: .quarter, notes: ChordNotes([note(64)]),
                graceNotesBefore: [grace(.appoggiatura, .eighth, 60)],
                graceNotesAfter: [grace(.grace16after, .sixteenth, 67)],
            )),
        ]))
        #expect(onsets(file, pitch: 64) == [240])
        #expect(onsets(file, pitch: 67) == [360])
        #expect(release(file, pitch: 64) == 359)
        #expect(release(file, pitch: 67) == 479)
    }
}
