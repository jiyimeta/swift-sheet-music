@testable import SheetMusicCore
import Testing

@Suite("Notation planning")
struct NotationPlanningTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// Measure 2 of the parity fixture, voice 0: the two tied E4 halves — the chain's only pair of adjacent
    /// sounding chords, so a `.between` tremolo and a glissando both have the follower they need.
    private static func bar2(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: 2, voiceIndex: 0, elementIndex: element)
    }

    private static func note2(_ element: Int, _ noteIndex: Int = 0) -> NoteID {
        NoteID(
            staff: flute,
            measureIndex: 2,
            voiceIndex: 0,
            elementIndex: element,
            noteIndexInChord: noteIndex,
        )
    }

    /// A slot no fixture measure reaches — every intent aimed here must plan to the COMMAND, so the command's own
    /// `apply` raises the refusal instead of the planner swallowing it.
    private static let missing = VoiceElementID(
        staff: flute, measureIndex: 9, voiceIndex: 0, elementIndex: 0,
    )
    private static let missingNote = NoteID(
        staff: flute, measureIndex: 9, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
    )

    @Test("a restating articulation plans to nothing, a different one plans to the command")
    func articulation() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.bar2(0)
        let write = EditIntent.setArticulation(at: target, kind: .staccato, anchor: .above, present: true)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) is SetArticulation)
        _ = try SetArticulation(at: target, kind: .staccato, anchor: .above, present: true).apply(to: &score)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) == nil)
        // A different anchor is not a restatement.
        let below = EditIntent.setArticulation(at: target, kind: .staccato, anchor: .below, present: true)
        #expect(ScoreEditSession.notationCommand(for: below, in: score) is SetArticulation)
        // Clearing a kind the chord does not carry IS a restatement.
        let clearOther = EditIntent.setArticulation(at: target, kind: .tenuto, anchor: nil, present: false)
        #expect(ScoreEditSession.notationCommand(for: clearOther, in: score) == nil)
    }

    @Test("grace notes restate only when both lists match")
    func graceNotes() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.bar2(0)
        let before = [GraceChord(graceType: .acciaccatura, duration: .sixteenth, notes: [Note(pitch: 63, tpc: 23)])]
        let write = EditIntent.setGraceNotes(at: target, before: before, after: [])
        #expect(ScoreEditSession.notationCommand(for: write, in: score) is SetGraceNotes)
        _ = try SetGraceNotes(at: target, before: before, after: []).apply(to: &score)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) == nil)
        // The same `before`, a different `after`: not a restatement.
        let after = [GraceChord(graceType: .grace16after, duration: .sixteenth, notes: [Note(pitch: 65, tpc: 13)])]
        let both = EditIntent.setGraceNotes(at: target, before: before, after: after)
        #expect(ScoreEditSession.notationCommand(for: both, in: score) is SetGraceNotes)
        // Clearing a chord that already carries nothing IS a restatement.
        let clear = EditIntent.setGraceNotes(at: Self.bar2(1), before: [], after: [])
        #expect(ScoreEditSession.notationCommand(for: clear, in: score) == nil)
    }

    @Test("a restating tremolo plans to nothing, nil on a bare chord too")
    func tremolo() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.bar2(0)
        let tremolo = Tremolo(subtype: .r16, span: .single, strokeStyle: .traditional)
        let write = EditIntent.setTremolo(at: target, tremolo: tremolo)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) is SetTremolo)
        _ = try SetTremolo(at: target, tremolo: tremolo).apply(to: &score)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) == nil)
        // A different stroke style is not a restatement.
        let other = EditIntent.setTremolo(at: target, tremolo: Tremolo(subtype: .r16, span: .single))
        #expect(ScoreEditSession.notationCommand(for: other, in: score) is SetTremolo)
        // Removing from a chord that carries none IS a restatement.
        #expect(ScoreEditSession.notationCommand(for: .setTremolo(at: Self.bar2(1), tremolo: nil), in: score) == nil)
    }

    @Test("arpeggio restates on the subtype alone")
    func arpeggio() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.bar2(0)
        _ = try AddNoteToChord(at: target, pitch: 67, tpc: 15, accidental: nil).apply(to: &score)
        let write = EditIntent.setArpeggio(at: target, subtype: 4)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) is SetArpeggio)
        _ = try SetArpeggio(at: target, arpeggio: Arpeggio(subtype: 4)).apply(to: &score)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) == nil)
        #expect(ScoreEditSession.notationCommand(for: .setArpeggio(at: target, subtype: 5), in: score) is SetArpeggio)
        // Removing from a chord that carries none IS a restatement.
        #expect(ScoreEditSession.notationCommand(for: .setArpeggio(at: Self.bar2(1), subtype: nil), in: score) == nil)
    }

    @Test("re-sending an arpeggio's subtype does not reset its timeStretch")
    func arpeggioPreservesTimeStretch() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.bar2(0)
        _ = try AddNoteToChord(at: target, pitch: 67, tpc: 15, accidental: nil).apply(to: &score)
        _ = try SetArpeggio(at: target, arpeggio: Arpeggio(subtype: 1, timeStretch: 3)).apply(to: &score)
        #expect(ScoreEditSession.notationCommand(for: .setArpeggio(at: target, subtype: 1), in: score) == nil)
        // The point of planning to nothing: the stretch the wire cannot carry survives the restatement.
        #expect(SetArpeggio.current(at: target, in: score)?.timeStretch == 3)
    }

    @Test("a restating glissando plans to nothing")
    func glissando() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.note2(0)
        let glissando = Glissando(style: .portamento, visualType: .wavy, easeIn: 25, easeOut: 75, text: "gliss.")
        let write = EditIntent.setGlissando(at: target, glissando: glissando)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) is SetGlissando)
        _ = try SetGlissando(at: target, glissando: glissando).apply(to: &score)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) == nil)
        let plain = EditIntent.setGlissando(at: target, glissando: Glissando())
        #expect(ScoreEditSession.notationCommand(for: plain, in: score) is SetGlissando)
        // Removing from a note that carries none IS a restatement.
        #expect(ScoreEditSession.notationCommand(
            for: .setGlissando(at: Self.note2(1), glissando: nil), in: score,
        ) == nil)
    }

    @Test("a restating dot count plans to nothing")
    func dots() throws {
        var score = EditingFixtures.parityFixture()
        let target = VoiceElementID(staff: Self.flute, measureIndex: 1, voiceIndex: 0, elementIndex: 0)
        // The fixture's bar-1 rests are undotted, so `dots: 0` is the restatement and `dots: 1` is not.
        #expect(ScoreEditSession.notationCommand(for: .setDots(at: target, dots: 0), in: score) == nil)
        #expect(ScoreEditSession.notationCommand(for: .setDots(at: target, dots: 1), in: score) is SetDots)
        _ = try SetDots(at: target, dots: 1).apply(to: &score)
        #expect(ScoreEditSession.notationCommand(for: .setDots(at: target, dots: 1), in: score) == nil)
        #expect(ScoreEditSession.notationCommand(for: .setDots(at: target, dots: 0), in: score) is SetDots)
    }

    @Test("a restating chord line plans to nothing, and a second line never restates")
    func chordLine() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.bar2(1)
        let write = EditIntent.setChordLine(at: target, kind: .fall, isStraight: false)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) is SetChordLine)
        _ = try SetChordLine(at: target, kind: .fall, isStraight: false).apply(to: &score)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) == nil)
        // `isStraight` is part of the comparison.
        let straight = EditIntent.setChordLine(at: target, kind: .fall, isStraight: true)
        #expect(ScoreEditSession.notationCommand(for: straight, in: score) is SetChordLine)
        // A chord carrying two lines never restates: the v1 single-line write genuinely changes it.
        guard case var .chord(chord)? = score[target] else { return #expect(Bool(false)) }
        chord.chordLines.append(ChordLine(kind: .doit, isStraight: false))
        score[target] = .chord(chord)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) is SetChordLine)
        // Clearing a chord with no lines IS a restatement.
        #expect(ScoreEditSession.notationCommand(
            for: .setChordLine(at: Self.bar2(0), kind: nil, isStraight: false), in: score,
        ) == nil)
    }

    @Test("restating note parentheses plans to nothing, and .none is the clear")
    func noteParentheses() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.note2(1)
        // `.none` on a plain note IS a restatement.
        #expect(ScoreEditSession.notationCommand(
            for: .setNoteParentheses(at: target, parentheses: .none), in: score,
        ) == nil)
        let write = EditIntent.setNoteParentheses(at: target, parentheses: .both)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) is SetNoteParentheses)
        _ = try SetNoteParentheses(at: target, parentheses: .both).apply(to: &score)
        #expect(ScoreEditSession.notationCommand(for: write, in: score) == nil)
        #expect(ScoreEditSession.notationCommand(
            for: .setNoteParentheses(at: target, parentheses: .none), in: score,
        ) is SetNoteParentheses)
    }

    @Test("an intent aimed at a missing target plans to the command, never to nothing", arguments: [
        EditIntent.setArticulation(at: missing, kind: .staccato, anchor: .above, present: true),
        EditIntent.setGraceNotes(at: missing, before: [], after: []),
        EditIntent.setTremolo(at: missing, tremolo: nil),
        EditIntent.setArpeggio(at: missing, subtype: nil),
        EditIntent.setGlissando(at: missingNote, glissando: nil),
        EditIntent.setDots(at: missing, dots: 0),
        EditIntent.setChordLine(at: missing, kind: nil, isStraight: false),
        EditIntent.setNoteParentheses(at: missingNote, parentheses: .none),
    ])
    func missingTargetPlansToTheCommand(intent: EditIntent) {
        let score = EditingFixtures.parityFixture()
        // Each intent is the CLEAR shape — the one a "compare against nothing" planner would wrongly call a
        // restatement. The refusal is the command's to raise.
        #expect(ScoreEditSession.notationCommand(for: intent, in: score) != nil)
    }
}
