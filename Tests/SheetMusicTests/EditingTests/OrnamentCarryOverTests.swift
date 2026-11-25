import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// What every edit that rebuilds or moves a chord does with its ornaments: the same as with its articulations, each
/// ornament with everything it carries. An edit that takes a chord's onset away — another note written over it, a copy
/// cut short — drops both.
@Suite("Ornaments carried through edits")
struct OrnamentCarryOverTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let staccato = ChordArticulation(kind: .staccato, anchor: .above)
    private static let trill = ChordOrnament(
        kind: .trill, intervalAbove: .init(step: .second, quality: .major), plays: false, accidentalAbove: .sharp,
        anchor: .bottom,
    )

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func note(_ measure: Int, _ element: Int, _ index: Int = 0) -> NoteID {
        NoteID(
            staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element, noteIndexInChord: index,
        )
    }

    private static func range(_ start: VoiceElementID, _ end: VoiceElementID) -> VoiceElementRange {
        VoiceElementRange(start: start, end: end)
    }

    private static func chord(_ pitch: Int, _ duration: NoteDuration, marked: Bool) -> VoiceElement {
        let tpc = [72: 14, 76: 18, 79: 15][pitch] ?? 14
        var chord = Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)])
        if marked {
            chord.articulations = [staccato]
            chord.ornaments = [trill]
        }
        return .chord(chord)
    }

    /// Bar 0: 4/4, a marked C5 quarter, a plain C5 quarter, a marked G5 half. Bar 1: a half and a quarter rest, then a
    /// marked E5 quarter. Bars 2 and 3: measure rests. `second` is bar 0's second voice.
    private static func score(second: [VoiceElement] = []) -> Score {
        var first = Measure(voices: [Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            chord(72, .quarter, marked: true), chord(72, .quarter, marked: false), chord(79, .half, marked: true),
        ])])
        if !second.isEmpty { first.voices.append(Voice(elements: second)) }
        return Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "flute"),
            staves: [Staff(defaultClefType: "G", measures: [
                first,
                Measure(voices: [Voice(elements: [
                    .rest(duration: .half), .rest(duration: .quarter), chord(76, .quarter, marked: true),
                ])]),
                Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
                Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
            ])],
        )])
    }

    private static func chords(_ score: Score) -> [(place: String, chord: Chord)] {
        score.parts[0].staves[0].measures.enumerated().flatMap { measureIndex, measure in
            measure.voices.enumerated().flatMap { voiceIndex, voice in
                voice.elements.values.compactMap { element -> (place: String, chord: Chord)? in
                    guard case let .chord(chord) = element, !chord.notes.isEmpty else { return nil }
                    let pitches = chord.notes.map { String($0.pitch) }.joined(separator: "+")
                    return (place: "\(measureIndex).\(voiceIndex) \(pitches)", chord: chord)
                }
            }
        }
    }

    /// The chords carrying the marks, after checking that each carries both or neither, whole.
    private static func carriers(
        _ score: Score, sourceLocation: SourceLocation = #_sourceLocation,
    ) -> [String] {
        let chords = chords(score)
        for (place, chord) in chords {
            let articulated = chord.articulations.contains(staccato)
            #expect(chord.ornaments == (articulated ? [trill] : []), "\(place)", sourceLocation: sourceLocation)
        }
        return chords.filter { !$0.chord.ornaments.isEmpty }.map(\.place)
    }

    struct Edit: Sendable, CustomTestStringConvertible {
        let name: String
        let intents: [EditIntent]
        /// The chords carrying the marks afterwards; the fixture's own are `0.0 72`, `0.0 79` and `1.0 76`.
        let carriers: [String]
        /// How many chords there are afterwards, where the edit makes one; the fixture has four.
        var chordCount = 4

        var testDescription: String {
            name
        }
    }

    private static let unmoved = ["0.0 72", "0.0 79", "1.0 76"]

    private static let edits: [Edit] = [
        Edit(name: "shorten", intents: [.setChordDuration(at: slot(0, 1), duration: .eighth)], carriers: unmoved),
        Edit(
            name: "lengthen over the next chord", intents: [.setChordDuration(at: slot(0, 1), duration: .half)],
            carriers: unmoved, chordCount: 3,
        ),
        Edit(
            name: "lengthen across the barline", intents: [.setChordDuration(at: slot(1, 2), duration: .half)],
            carriers: unmoved, chordCount: 5,
        ),
        Edit(name: "dot", intents: [.setDots(at: slot(0, 1), dots: 1)], carriers: unmoved),
        Edit(
            name: "a range's duration",
            intents: [.setDurationInRange(over: range(slot(0, 1), slot(0, 2)), duration: .eighth)], carriers: unmoved,
        ),
        Edit(
            name: "re-time a run",
            intents: [.retimeRun(
                at: slot(0, 1), durations: [.eighth, .fraction(Fraction(numerator: 3, denominator: 8))],
            )],
            carriers: unmoved,
        ),
        Edit(
            name: "write a note over it, re-timed in the bar",
            intents: [.writeNote(at: slot(0, 1), pitch: 74, tpc: 16, duration: .eighth)],
            carriers: ["0.0 74", "0.0 79", "1.0 76"],
        ),
        Edit(
            name: "re-pitch", intents: [.setNotePitch(at: note(0, 1), pitch: 74, tpc: 16, accidental: nil)],
            carriers: ["0.0 74", "0.0 79", "1.0 76"],
        ),
        Edit(
            name: "accidental", intents: [.setAccidental(at: note(0, 1), accidental: .sharp)],
            carriers: ["0.0 73", "0.0 79", "1.0 76"],
        ),
        Edit(
            name: "add a note, then take it off",
            intents: [
                .addNoteToChord(at: slot(0, 1), pitch: 76, tpc: 18, accidental: nil),
                .removeNoteFromChord(at: note(0, 1, 1)),
            ],
            carriers: unmoved,
        ),
        Edit(
            name: "an interval over a range",
            intents: [.addIntervalToSelection(over: range(slot(0, 1), slot(1, 2)), steps: 8)],
            carriers: ["0.0 72+84", "0.0 79+91", "1.0 76+88"],
        ),
        Edit(
            name: "tie",
            intents: [.setTie(from: note(0, 1), to: note(0, 2), sourceTieForward: 1, targetTieBack: 1)],
            carriers: unmoved,
        ),
        Edit(
            name: "move to the second voice",
            intents: [.moveToVoice(
                at: slot(0, 1), to: VoiceRef(staff: staff, measureIndex: 0, voiceIndex: 1),
            )],
            carriers: ["0.0 79", "0.1 72", "1.0 76"],
        ),
        Edit(
            name: "duplicate", intents: [.duplicateRange(over: range(slot(0, 1), slot(0, 1)))],
            carriers: ["0.0 72", "0.0 72", "0.0 79", "1.0 76"],
        ),
        Edit(
            name: "duplicate across a barline", intents: [.duplicateRange(over: range(slot(0, 2), slot(0, 3)))],
            carriers: ["0.0 72", "0.0 79", "1.0 79", "1.0 76"], chordCount: 6,
        ),
        Edit(
            name: "transpose a range",
            intents: [.transposeRange(over: range(slot(0, 1), slot(0, 3)), semitones: 12, respellInKey: false)],
            carriers: ["0.0 84", "0.0 91", "1.0 76"],
        ),
        Edit(
            name: "transpose the score",
            intents: [.transposeScore(semitones: 12, transposeKeySignatures: true, respellInKey: false)],
            carriers: ["0.0 84", "0.0 91", "1.0 88"],
        ),
        Edit(
            name: "a meter whose barline cuts the half",
            intents: [.setTimeSignature(measureIndex: 0, numerator: 3, denominator: 4, symbol: .numeric)],
            carriers: ["0.0 72", "0.0 79", "2.0 76"], chordCount: 5,
        ),
        Edit(
            name: "a tuplet on it, and back",
            intents: [
                .createTuplet(at: slot(0, 1), actualNotes: 3, normalNotes: 2), .removeTuplet(at: slot(0, 1)),
            ],
            carriers: unmoved,
        ),
        Edit(name: "an inserted bar", intents: [.insertMeasure(at: 1)], carriers: ["0.0 72", "0.0 79", "2.0 76"]),
        Edit(
            name: "the chord's other marks",
            intents: [
                .setArticulation(at: slot(0, 1), kind: .accent, anchor: nil, present: true),
                .setGraceNotes(
                    at: slot(0, 1),
                    before: [GraceChord(
                        graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 74, tpc: 16)],
                    )],
                    after: [],
                ),
                .setTremolo(at: slot(0, 1), tremolo: Tremolo(subtype: .r16)),
                .setChordLine(at: slot(0, 1), kind: .fall, isStraight: false),
                .setStemVisible(at: slot(0, 1), visible: false),
                .setElementVisible(at: slot(0, 1), visible: false),
            ],
            carriers: unmoved,
        ),
    ]

    @Test("an edit that keeps the chord keeps its ornaments, as its articulations", arguments: edits)
    func edit(_ edit: Edit) throws {
        let session = ScoreEditSession(score: Self.score())
        let before = session.score
        for intent in edit.intents {
            try #require(session.apply(intent), "refused: \(String(describing: session.lastRefusal))")
        }
        #expect(Self.carriers(session.score) == edit.carriers)
        #expect(Self.chords(session.score).count == edit.chordCount)
        for _ in edit.intents {
            #expect(session.undo())
        }
        #expect(session.score.stableFingerprint == before.stableFingerprint)
        #expect(Self.carriers(session.score) == Self.unmoved)
    }

    @Test("copy and paste carries it through the clipboard document")
    func copyPaste() throws {
        var score = Self.score()
        let document = try #require(score.clipboardDocument(for: Self.range(Self.slot(0, 1), Self.slot(0, 3))))
        let text = try #require(String(data: MSCXEncoder.encode(document), encoding: .utf8))
        _ = try PasteRange(at: Self.slot(2, 0), payload: text, readPayload: MSCXParser.parse).apply(to: &score)
        #expect(Self.carriers(score) == Self.unmoved + ["2.0 72", "2.0 79"])
    }

    @Test("a display transposition keeps them")
    func displayTransposition() {
        #expect(Self.carriers(Self.score().transposed(bySemitones: 2)) == ["0.0 74", "0.0 81", "1.0 78"])
    }

    @Test("drum voice conversion gives them to each part of a chord it splits, as a mark that plays")
    func drumRevoice() throws {
        let score = RevoiceFixtures.editingChord(
            RevoiceFixtures.score([["H+K/4 H/4 H/4 H/4"]]), measure: 0, voice: 0, element: 1,
        ) { chord in
            chord.articulations = [Self.staccato]
            chord.ornaments = [Self.trill]
        }
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(Self.carriers(after) == ["0.0 42", "0.1 36"])
    }

    /// The edits that drop the marks: each takes the chord's onset away and leaves at most a tied continuation of it,
    /// or a copy with its length re-spelled. The articulations go the same way; `carriers` is what says so.
    private static let drops: [Edit] = [
        Edit(
            name: "another note lengthened over its head",
            intents: [.setChordDuration(at: slot(0, 2), duration: .half)], carriers: ["0.0 72", "1.0 76"],
        ),
        Edit(
            name: "a note written over it, re-timed across the barline",
            intents: [.writeNote(at: slot(1, 2), pitch: 77, tpc: 13, duration: .half)], carriers: ["0.0 72", "0.0 79"],
            chordCount: 5,
        ),
        Edit(
            name: "a duplicate landing on its head",
            intents: [.duplicateRange(over: range(slot(0, 2), slot(0, 2)))], carriers: ["0.0 72", "1.0 76"],
            chordCount: 5,
        ),
    ]

    @Test("an edit that takes the chord's onset away drops its ornaments, as its articulations", arguments: drops)
    func drop(_ edit: Edit) throws {
        let session = ScoreEditSession(score: Self.score())
        for intent in edit.intents {
            try #require(session.apply(intent), "refused: \(String(describing: session.lastRefusal))")
        }
        #expect(Self.carriers(session.score) == edit.carriers)
        #expect(Self.chords(session.score).count == edit.chordCount)
    }

    @Test("a copy cut short by the range's end drops them, as its articulations")
    func cutCopy() throws {
        // The second voice's marked whole note starts inside the range and sounds past its end; its copy lands on the
        // half it still sounded for.
        let session = ScoreEditSession(score: Self.score(second: [Self.chord(72, .whole, marked: true)]))
        let range = Self.range(Self.slot(0, 1), Self.slot(0, 2))
        try #require(session.apply(.duplicateRange(over: range)))
        #expect(Self.carriers(session.score) == ["0.0 72", "0.0 72", "0.1 72", "1.0 76"])
        #expect(Self.chords(session.score).filter { $0.place == "0.1 72" }.map(\.chord.duration) == [.half, .half])
    }
}
