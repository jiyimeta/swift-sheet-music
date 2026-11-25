@testable import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicMIDI
import Testing

/// Trills, mordents and turns as sounded notes. The tempo is the default 120 a minute, where a trill's notes are
/// 32nds (60 ticks).
@Suite("Ornament playback")
struct OrnamentPlaybackTests {
    private let division = 480

    /// A note from MuseScore's tonal pitch class (C 14, G 15, D 16, A 17, E 18, B 19, F 13, F♯ 20).
    private func note(_ pitch: Int, _ tpc: Int, tieForward: Bool = false, tieBack: Bool = false) -> Note {
        var note = Note(pitch: pitch, tpc: tpc)
        if tieForward { note.tieForward = 1 }
        if tieBack { note.tieBack = 1 }
        return note
    }

    private func chord(
        _ duration: NoteDuration, _ notes: [Note], _ kinds: [ChordOrnament.Kind] = [],
    ) -> Chord {
        Chord(duration: duration, notes: ChordNotes(notes), ornaments: kinds.map { ChordOrnament(kind: $0) })
    }

    private func score(_ bars: [[VoiceElement]], drums: Bool = false) -> Score {
        let staff = Staff(measures: bars.map { Measure(voices: [Voice(elements: $0)]) })
        var instrument = Instrument(id: "piano", articulations: [InstrumentArticulation()])
        instrument.useDrumset = drums
        return Score(division: division, parts: [Part(id: "P1", instrument: instrument, staves: [staff])])
    }

    private func sounded(_ score: Score) throws -> [(pitch: Int, on: Int, off: Int)] {
        var open: [Int: Int] = [:]
        var result: [(pitch: Int, on: Int, off: Int)] = []
        for event in try MidiRenderer.renderForPlayback(score: score).tracks.flatMap(\.events) {
            switch event.event {
            case let .noteOn(_, pitch, velocity) where velocity > 0:
                #expect(open[pitch] == nil, "\(pitch) struck twice without a release")
                open[pitch] = event.tick
            case let .noteOff(_, pitch, _):
                if let on = open.removeValue(forKey: pitch) { result.append((pitch, on, event.tick)) }
            default: break
            }
        }
        #expect(open.isEmpty, "left sounding: \(open)")
        return result.sorted { ($0.on, $0.pitch) < ($1.on, $1.pitch) }
    }

    private func pitches(_ score: Score) throws -> [Int] {
        try sounded(score).map(\.pitch)
    }

    @Test("a trill alternates with the note above, from the written note, across the whole note")
    func trill() throws {
        let notes = try sounded(score([[.chord(chord(.quarter, [note(60, 14)], [.trill]))]]))
        #expect(notes.map(\.pitch) == [60, 62, 60, 62, 60, 62, 60, 62])
        #expect(notes.map(\.on) == [0, 60, 120, 180, 240, 300, 360, 420])
        #expect(notes.last?.off == 479)
    }

    @Test("the note above is the key's", arguments: [(0, 65), (1, 66), (-1, 65)])
    func keySignature(key: Int, above: Int) throws {
        let bar: [VoiceElement] = [
            .keySignature(KeySignature(concertKey: key)), .chord(chord(.quarter, [note(64, 18)], [.trill])),
        ]
        #expect(try Set(pitches(score([bar]))) == [64, above])
    }

    @Test("the key is the one in force at the bar, not the score's first")
    func laterKey() throws {
        let bars: [[VoiceElement]] = [
            [.chord(chord(.whole, [note(64, 18)], [.trill]))],
            [.keySignature(KeySignature(concertKey: 1)), .chord(chord(.whole, [note(64, 18)], [.trill]))],
            [.chord(chord(.whole, [note(64, 18)], [.trill]))],
        ]
        let notes = try sounded(score(bars))
        let above = [0, 1, 2].map { bar in
            Set(notes.filter { $0.on / 1920 == bar }.map(\.pitch)).subtracting([64])
        }
        #expect(above == [[65], [66], [66]])
    }

    @Test("an accidental earlier in the bar reaches the note above; one in another bar, or later, does not")
    func accidentalInTheBar() throws {
        let sharp = chord(.quarter, [note(66, 20)])
        let trilled = chord(.quarter, [note(64, 18)], [.trill])
        #expect(try Set(pitches(score([[.chord(sharp), .chord(trilled)]]))) == [64, 66])
        #expect(try Set(pitches(score([[.chord(trilled), .chord(sharp)]]))) == [64, 65, 66])
        let acrossBars = try sounded(score([[.chord(sharp)], [.chord(trilled)]]))
        #expect(Set(acrossBars.map(\.pitch)) == [64, 65, 66])
    }

    @Test("a stated interval wins over the key")
    func statedInterval() throws {
        var trilled = chord(.quarter, [note(64, 18)])
        trilled.ornaments = [ChordOrnament(
            kind: .trill, intervalAbove: ChordOrnament.Interval(step: .second, quality: .major),
        )]
        #expect(try Set(pitches(score([[.chord(trilled)]]))) == [64, 66])
    }

    @Test("mordents and turns play their notes first and hold the written one", arguments: [
        (ChordOrnament.Kind.mordent, [60, 59, 60]),
        (.shortTrill, [60, 62, 60]),
        (.turn, [62, 60, 59, 60]),
        (.turnInverted, [59, 60, 62, 60]),
    ])
    func heldFigures(kind: ChordOrnament.Kind, expected: [Int]) throws {
        let notes = try sounded(score([[.chord(chord(.quarter, [note(60, 14)], [kind]))]]))
        #expect(notes.map(\.pitch) == expected)
        #expect(notes.map(\.on) == (0 ..< expected.count).map { $0 * 60 })
        #expect(notes.last?.off == 479)
    }

    @Test("every kind plays inside its note and ends with it", arguments: ChordOrnament.Kind.modeled)
    func everyKindFits(kind: ChordOrnament.Kind) throws {
        for duration in [NoteDuration.whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond] {
            let ticks = duration.ticks(division: division)
            let notes = try sounded(score([[.chord(chord(duration, [note(60, 14)], [kind]))]]))
            #expect(notes.first?.on == 0)
            #expect(notes.allSatisfy { $0.on < ticks && $0.off >= $0.on && $0.off < ticks }, "\(kind) \(duration)")
            #expect(notes.map(\.off).max() == ticks - 1, "\(kind) \(duration)")
            #expect(zip(notes, notes.dropFirst()).allSatisfy { $0.off < $1.on }, "\(kind) \(duration)")
        }
    }

    @Test("a turn on a note too short for its pace is played evenly")
    func squeezedTurn() throws {
        let notes = try sounded(score([[.chord(chord(.sixteenth, [note(60, 14)], [.turn]))]]))
        #expect(notes.map(\.pitch) == [62, 60, 59, 60])
        #expect(notes.map(\.on) == [0, 30, 60, 90])
    }

    @Test("an ornament the user silenced, and a symbol with no realization, play the note plain")
    func silent() throws {
        var muted = chord(.quarter, [note(60, 14)])
        muted.ornaments = [ChordOrnament(kind: .trill, plays: false)]
        #expect(try pitches(score([[.chord(muted)]])) == [60])
        let unknown = chord(.quarter, [note(60, 14)], [.unknown(subtype: "ornamentSomething")])
        #expect(try pitches(score([[.chord(unknown)]])) == [60])
    }

    @Test("a drum staff keeps its note")
    func drums() throws {
        let bar: [VoiceElement] = [.chord(chord(.quarter, [note(38, 16)], [.trill]))]
        #expect(try pitches(score([bar], drums: true)) == [38])
    }

    @Test("a trill runs on through a tie, and nothing is left sounding")
    func tiedTrill() throws {
        let notes = try sounded(score([[
            .chord(chord(.quarter, [note(60, 14, tieForward: true)], [.trill])),
            .chord(chord(.quarter, [note(60, 14, tieBack: true)])),
        ]]))
        #expect(notes.map(\.pitch) == Array(repeating: [60, 62], count: 8).flatMap(\.self))
        #expect(notes.last?.off == 959)
    }

    @Test("a turn holds its last note through a tie")
    func tiedTurn() throws {
        let notes = try sounded(score([[
            .chord(chord(.quarter, [note(60, 14, tieForward: true)], [.turn])),
            .chord(chord(.quarter, [note(60, 14, tieBack: true)])),
        ]]))
        #expect(notes.map(\.pitch) == [62, 60, 59, 60])
        #expect(notes.last?.on == 180)
        #expect(notes.last?.off == 959)
    }

    @Test("a tied trill is struck again by a link too short to carry it")
    func tiedTrillIntoAShortLink() throws {
        let notes = try sounded(score([[
            .chord(chord(.quarter, [note(60, 14, tieForward: true)], [.trill])),
            .chord(chord(.sixtyFourth, [note(60, 14, tieBack: true)])),
        ]]))
        #expect(notes.last?.pitch == 62 || notes.last?.pitch == 60)
        #expect(notes.last?.off == 509)
    }

    @Test("a trill line trills every note it covers, and stops at its end")
    func trillLine() throws {
        let line = Spanner(
            kind: .trill, rawType: "Trill", nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 2, denominator: 4),
            trill: Spanner.TrillPayload(type: .trill),
        )
        let notes = try sounded(score([[
            .spanner(line),
            .chord(chord(.quarter, [note(60, 14)])),
            .chord(chord(.quarter, [note(62, 16)])),
            .chord(chord(.quarter, [note(64, 18)])),
        ]]))
        #expect(Set(notes.filter { $0.on < 480 }.map(\.pitch)) == [60, 62])
        #expect(Set(notes.filter { (480 ..< 960).contains($0.on) }.map(\.pitch)) == [62, 64])
        #expect(notes.filter { $0.on >= 960 }.map(\.pitch) == [64])
    }

    @Test("a grace note before a trill comes first")
    func graceBeforeTrill() throws {
        var trilled = chord(.quarter, [note(60, 14)], [.trill])
        trilled.graceNotesBefore = [GraceChord(
            graceType: .acciaccatura, duration: .eighth, notes: ChordNotes([note(59, 19)]),
        )]
        let notes = try sounded(score([[.chord(trilled)]]))
        #expect(notes.prefix(3).map(\.pitch) == [59, 60, 62])
        #expect(notes.prefix(2).map(\.on) == [0, 30])
        #expect(notes.last?.off == 479)
    }
}
