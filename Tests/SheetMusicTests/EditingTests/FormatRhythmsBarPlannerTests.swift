@testable import SheetMusicCore
import Testing

/// One bar-voice re-spelled. Every expected spelling below is the output of the validated Python reference
/// (`fmt_policy2.py`'s `predict`, via `gen_task2_cases.py`), not a hand derivation, except where a §4.1 / §4.2 rule has
/// no Python counterpart — those tests assert "left exactly as written" (`nil`).
@Suite("FormatRhythmsBarPlanner")
struct FormatRhythmsBarPlannerTests {
    static let division = 480

    // MARK: Builders

    static func duration(_ numerator: Int, _ denominator: Int) -> NoteDuration {
        .canonical(Fraction(numerator: numerator, denominator: denominator))
    }

    static func note(
        _ numerator: Int, _ denominator: Int, pitch: Int = 60, tpc: Int = 14,
        tieForward: Bool = false, tieBack: Bool = false,
    ) -> VoiceElement {
        .chord(chord(numerator, denominator, pitch: pitch, tpc: tpc, tieForward: tieForward, tieBack: tieBack))
    }

    static func chord(
        _ numerator: Int, _ denominator: Int, pitch: Int = 60, tpc: Int = 14,
        tieForward: Bool = false, tieBack: Bool = false,
    ) -> Chord {
        Chord(duration: duration(numerator, denominator), notes: [
            Note(pitch: pitch, tpc: tpc, tieForward: tieForward ? 1 : nil, tieBack: tieBack ? 1 : nil),
        ])
    }

    static func rest(_ numerator: Int, _ denominator: Int) -> VoiceElement {
        .rest(duration: duration(numerator, denominator))
    }

    /// A voice with assigned identifiers (the fixtures' `Score` mints them).
    static func voice(_ elements: [VoiceElement], tuplets: [Tuplet] = []) -> Voice {
        VoiceIdentityFixtures.score([[Voice(elements: elements, tuplets: tuplets)]])
            .parts[0].staves[0].measures[0].voices[0]
    }

    static func facts(
        meter: (Int, Int) = (4, 4), barTicks: Int? = nil, pickup: Bool = false,
        window: Range<Int>? = nil, protected: Set<Int> = [],
    ) -> FormatRhythmsBarFacts {
        FormatRhythmsBarFacts(
            meterNumerator: meter.0, meterDenominator: meter.1,
            barTicks: barTicks ?? meter.0 * 4 * division / meter.1, isPickup: pickup, division: division,
            window: window, protectedOnsets: protected,
        )
    }

    static func respell(
        _ voice: Voice, _ facts: FormatRhythmsBarFacts = facts(), _ policy: RhythmSpellingPolicy = .default,
    ) -> (slots: [VoiceSlot], tupletSlots: [TupletSlot])? {
        FormatRhythmsBarPlanner.respell(voice, facts: facts, policy: policy)
    }

    /// `C:3/8~` — a chord of 3/8 of a whole note whose notes tie forward; `R:` a rest; `other` anything untimed.
    static func tokens(_ slots: [VoiceSlot]) -> [String] {
        slots.map { slot in
            guard case let .chord(chord) = slot.element else { return "other" }
            let text: String = if case .measure = chord.duration {
                "measure"
            } else {
                {
                    let fraction = Fraction(ticks: chord.duration.ticks(division: division), division: division)
                    return "\(fraction.numerator)/\(fraction.denominator)"
                }()
            }
            let tied = chord.notes.contains { $0.tieForward != nil } ? "~" : ""
            return (chord.notes.isEmpty ? "R:" : "C:") + text + tied
        }
    }

    static func chord(of element: VoiceElement) -> Chord? {
        if case let .chord(chord) = element { chord } else { nil }
    }

    static func chord(at index: Int, in slots: [VoiceSlot]) -> Chord? {
        if case let .chord(chord) = slots[index].element { chord } else { nil }
    }

    static let afterGrace = GraceChord(graceType: .grace8after, duration: .eighth, notes: [Note(pitch: 67, tpc: 15)])
    static let beforeGrace = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 61, tpc: 21)])

    static let thirdBarFlaw = [
        note(1, 4), note(1, 8, pitch: 62), note(1, 2, pitch: 64), note(1, 8, pitch: 65),
    ]

    // MARK: Owner examples

    @Test("owner example: half at 3/8 becomes eighth tied to dotted quarter, head keeps its EID")
    func halfAtThreeEighths() throws {
        let voice = Self.voice(Self.thirdBarFlaw)
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["C:1/4", "C:1/8", "C:1/8~", "C:3/8", "C:1/8"])
        #expect(result.slots[2].identity == .keep(voice.elements.eid(at: 2)))
        #expect(result.slots[3].identity == .fresh)
        for index in [0, 1, 4] {
            #expect(result.slots[index].identity == .keep(voice.elements.eid(at: index == 4 ? 3 : index)))
        }
        let tail = try #require(Self.chord(at: 3, in: result.slots))
        #expect(tail.notes[0].tieBack == 1)
        #expect(tail.notes[0].tieForward == nil)
        let head = try #require(Self.chord(at: 2, in: result.slots))
        #expect(head.notes[0].tieBack == nil)
        #expect(head.notes[0].pitch == 64 && tail.notes[0].pitch == 64)
    }

    @Test("owner example: eighth tied to quarter at 5/8 merges into a dotted quarter")
    func eighthTiedToQuarterMerges() throws {
        let voice = Self.voice([
            Self.note(1, 2), Self.note(1, 8, pitch: 62),
            Self.note(1, 8, pitch: 64, tieForward: true), Self.note(1, 4, pitch: 64, tieBack: true),
        ])
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["C:1/2", "C:1/8", "C:3/8"])
        #expect(result.slots[2].identity == .keep(voice.elements.eid(at: 2)))
        let merged = try #require(Self.chord(at: 2, in: result.slots))
        #expect(merged.notes[0].tieForward == nil && merged.notes[0].tieBack == nil)
        #expect(try merged.notes.eid(at: 0) == (#require(Self.chord(of: voice.elements.values[2])).notes.eid(at: 0)))
    }

    @Test("untied dotted quarter at 3/8 splits into eighth tied to quarter")
    func dottedQuarterAtThreeEighths() throws {
        let voice = Self.voice([
            Self.note(1, 4), Self.note(1, 8, pitch: 62), Self.note(3, 8, pitch: 64), Self.note(1, 4, pitch: 65),
        ])
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["C:1/4", "C:1/8", "C:1/8~", "C:1/4", "C:1/4"])
    }

    // MARK: keepWritten

    @Test("keepWritten: a written quarter rest at 1/8 stays; two eighth rests at 1/8 and 1/4 stay two")
    func keepWrittenRests() {
        #expect(Self.respell(Self.voice([
            Self.note(1, 8), Self.rest(1, 4), Self.note(1, 8, pitch: 62), Self.note(1, 2, pitch: 64),
        ])) == nil)
        #expect(Self.respell(Self.voice([
            Self.note(1, 8), Self.rest(1, 8), Self.rest(1, 8), Self.note(1, 8, pitch: 62), Self.note(1, 2, pitch: 64),
        ])) == nil)
    }

    @Test(
        "keepWritten: 3/4 quarter rests on beats 2 and 3 stay; quarter rest pair at beat 1 of 4/4 becomes a half rest",
    )
    func keepWrittenRestsInTriple() throws {
        let triple = Self.voice([Self.note(1, 4), Self.rest(1, 4), Self.rest(1, 4)])
        #expect(Self.respell(triple, Self.facts(meter: (3, 4))) == nil)
        let voice = Self.voice([Self.rest(1, 4), Self.rest(1, 4), Self.note(1, 2)])
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["R:1/2", "C:1/2"])
        #expect(result.slots[0].identity == .fresh)
        #expect(result.slots[1].identity == .keep(voice.elements.eid(at: 2)))
    }

    @Test("keepWritten notes: a written half at beat 2 stays; a quarter~quarter tie from beat 2 stays tied")
    func keepWrittenNotes() throws {
        let policy = RhythmSpellingPolicy(
            dotLevel: .double, midBarSyncopations: .keepWritten, beatCrossingRests: .keepWritten,
        )
        let allow = RhythmSpellingPolicy(dotLevel: .double, midBarSyncopations: .allow, beatCrossingRests: .keepWritten)
        let half = Self.voice([Self.note(1, 4), Self.note(1, 2, pitch: 62), Self.note(1, 4, pitch: 64)])
        #expect(Self.respell(half, Self.facts(), policy) == nil)
        // Under `.split` the same written half is split (fmt_policy2: C:1/4 C:1/4~ C:1/4 C:1/4).
        let split = try #require(Self.respell(half, Self.facts(), .default))
        #expect(Self.tokens(split.slots) == ["C:1/4", "C:1/4~", "C:1/4", "C:1/4"])
        let tied = Self.voice([
            Self.note(1, 4), Self.note(1, 4, pitch: 62, tieForward: true), Self.note(1, 4, pitch: 62, tieBack: true),
            Self.note(1, 4, pitch: 64),
        ])
        #expect(Self.respell(tied, Self.facts(), policy) == nil)
        // Under `.allow` the tied pair is MERGED into a half (fmt_policy2: C:1/4 C:1/2 C:1/4).
        let merged = try #require(Self.respell(tied, Self.facts(), allow))
        #expect(Self.tokens(merged.slots) == ["C:1/4", "C:1/2", "C:1/4"])
    }

    @Test("split: a written half at beat 2 becomes quarter~quarter")
    func splitHalfAtBeatTwo() throws {
        let voice = Self.voice([Self.note(1, 4), Self.note(1, 2, pitch: 62), Self.note(1, 4, pitch: 64)])
        let result = try #require(Self.respell(voice, Self.facts(), .default))
        #expect(Self.tokens(result.slots) == ["C:1/4", "C:1/4~", "C:1/4", "C:1/4"])
    }

    // MARK: Absorb rule (§4.2)

    struct BlockedMerge: CustomTestStringConvertible, Sendable {
        let name: String
        let elements: [VoiceElement]
        var testDescription: String {
            name
        }
    }

    /// Quarter ~ quarter at 0 and 1/4, then a half: absorbing would make a half at 0, so any `nil` below means the
    /// second quarter was NOT absorbed.
    static func tiedPair(
        continuation: (inout Chord) -> Void = { _ in }, between: [VoiceElement] = [],
        head: (inout Chord) -> Void = { _ in },
    ) -> [VoiceElement] {
        var first = chord(1, 4, tieForward: true)
        head(&first)
        var second = chord(1, 4, tieBack: true)
        continuation(&second)
        return [.chord(first)] + between + [.chord(second), note(1, 2, pitch: 62)]
    }

    static let blockedMerges: [BlockedMerge] = [
        BlockedMerge(name: "lyric", elements: tiedPair { $0.lyrics = [Lyric(text: "la")] }),
        BlockedMerge(name: "articulation", elements: tiedPair {
            $0.articulations = [ChordArticulation(kind: .tenuto)]
        }),
        BlockedMerge(name: "grace before", elements: tiedPair {
            $0.graceNotesBefore = [
                GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 61, tpc: 21)]),
            ]
        }),
        BlockedMerge(name: "slur begin", elements: tiedPair { $0.spanners = [Spanner(kind: .slur, rawType: "Slur")] }),
        BlockedMerge(name: "color", elements: tiedPair {
            $0.elementProperties.color = ScoreColor(red: 255, green: 0, blue: 0)
        }),
        BlockedMerge(name: "beam hidden", elements: tiedPair { $0.beamVisible = false }),
        BlockedMerge(name: "different tpc", elements: [
            note(1, 4, tieForward: true), note(1, 4, tpc: 21, tieBack: true), note(1, 2, pitch: 62),
        ]),
        BlockedMerge(name: "partial tie", elements: [
            .chord(Chord(duration: .quarter, notes: [
                Note(pitch: 60, tpc: 14, tieForward: 1), Note(pitch: 64, tpc: 18),
            ])),
            .chord(Chord(duration: .quarter, notes: [
                Note(pitch: 60, tpc: 14, tieBack: 1), Note(pitch: 64, tpc: 18),
            ])),
            note(1, 2, pitch: 62),
        ]),
        BlockedMerge(name: "different pitch", elements: [
            note(1, 4, tieForward: true), note(1, 4, pitch: 62, tieBack: true), note(1, 2, pitch: 64),
        ]),
        BlockedMerge(name: "ornament", elements: tiedPair { $0.ornaments = [ChordOrnament(kind: .turn)] }),
        BlockedMerge(name: "bracket", elements: tiedPair { $0.bracket = ChordBracket() }),
        BlockedMerge(name: "stem hidden", elements: tiedPair { $0.stemVisible = false }),
        BlockedMerge(name: "head type", elements: tiedPair {
            $0.notes.updateNote(at: 0) { $0.headType = "cross" }
        }),
        BlockedMerge(name: "after-graces", elements: tiedPair {
            $0.graceNotesAfter = [afterGrace]
        }),
        BlockedMerge(name: "note fingering", elements: tiedPair {
            $0.notes.updateNote(at: 0) { $0.fingerings = [Fingering(text: "3")] }
        }),
        BlockedMerge(name: "dynamic between", elements: tiedPair(between: [
            .dynamic(Dynamic(subtype: "p", velocity: 49)),
        ])),
        BlockedMerge(name: "location shift between", elements: tiedPair(between: [
            .locationShift(delta: Fraction(numerator: 0, denominator: 1)),
        ])),
    ]

    @Test("a continuation that is not bare is not absorbed", arguments: blockedMerges)
    func blockedContinuation(_ example: BlockedMerge) {
        #expect(Self.respell(Self.voice(example.elements)) == nil)
    }

    @Test("a fully tied two-note chord IS absorbed (control for the partial-tie case)")
    func twoNoteChordMerges() throws {
        let result = try #require(Self.respell(Self.voice([
            .chord(Chord(duration: .quarter, notes: [
                Note(pitch: 60, tpc: 14, tieForward: 1), Note(pitch: 64, tpc: 18, tieForward: 1),
            ])),
            .chord(Chord(duration: .quarter, notes: [
                Note(pitch: 60, tpc: 14, tieBack: 1), Note(pitch: 64, tpc: 18, tieBack: 1),
            ])),
            Self.note(1, 2, pitch: 62),
        ])))
        #expect(Self.tokens(result.slots) == ["C:1/2", "C:1/2"])
        #expect(try #require(Self.chord(at: 0, in: result.slots)).notes.count == 2)
    }

    @Test("a bare tie continuation IS absorbed (control for the blocked-merge cases)")
    func bareContinuationMerges() throws {
        let result = try #require(Self.respell(Self.voice(Self.tiedPair())))
        #expect(Self.tokens(result.slots) == ["C:1/2", "C:1/2"])
    }

    @Test("protected onset stops a merge")
    func protectedOnset() {
        let voice = Self.voice(Self.tiedPair())
        #expect(Self.respell(voice, Self.facts(protected: [480])) == nil)
        #expect(Self.respell(voice, Self.facts(protected: [960])) != nil)
    }

    // MARK: Duration-sensitive spans (§4.1)

    struct Untouchable: CustomTestStringConvertible, Sendable {
        let name: String
        let elements: [VoiceElement]
        var testDescription: String {
            name
        }
    }

    /// The badly placed half of `thirdBarFlaw`, with `attach` applied to it, optionally flanked by a stream element.
    static func flawed(
        before: [VoiceElement] = [], after: [VoiceElement] = [], attach: (inout Chord) -> Void = { _ in },
    ) -> [VoiceElement] {
        var half = chord(1, 2, pitch: 64)
        attach(&half)
        return [note(1, 4), note(1, 8, pitch: 62)] + before + [.chord(half)] + after + [note(1, 8, pitch: 65)]
    }

    static let untouchables: [Untouchable] = [
        Untouchable(name: "staccato", elements: flawed {
            $0.articulations = [ChordArticulation(kind: .staccato)]
        }),
        Untouchable(name: "appoggiatura before", elements: flawed {
            $0.graceNotesBefore = [
                GraceChord(graceType: .appoggiatura, duration: .eighth, notes: [Note(pitch: 66, tpc: 20)]),
            ]
        }),
        Untouchable(name: "single-chord tremolo", elements: flawed {
            $0.tremolo = Tremolo(subtype: .r16, span: .single)
        }),
        Untouchable(name: "arpeggio", elements: flawed { $0.arpeggio = Arpeggio(subtype: 0) }),
        Untouchable(name: "ornament", elements: flawed { $0.ornaments = [ChordOrnament(kind: .turn)] }),
        Untouchable(name: "chord line", elements: flawed { $0.chordLines = [ChordLine(kind: .fall)] }),
        Untouchable(name: "guitar bend", elements: flawed {
            $0.notes.updateNote(at: 0) { $0.guitarBend = GuitarBend(type: .bend) }
        }),
        Untouchable(name: "two-note tremolo", elements: flawed {
            $0.tremolo = Tremolo(subtype: .r16, span: .between)
        }),
        Untouchable(name: "note glissando", elements: flawed {
            $0.notes.updateNote(at: 0) { $0.glissando = Glissando() }
        }),
        Untouchable(name: "fermata right before", elements: flawed(before: [
            .fermata(Fermata(subtype: "fermataAbove")),
        ])),
        Untouchable(name: "fermata right after", elements: flawed(after: [
            .fermata(Fermata(subtype: "fermataAbove")),
        ])),
        Untouchable(name: "breath right after", elements: flawed(after: [.breath(Breath(kind: .breathMark(.comma)))])),
    ]

    @Test("duration-sensitive attachment leaves the span untouched", arguments: untouchables)
    func untouchableSpan(_ example: Untouchable) {
        #expect(Self.respell(Self.voice(example.elements)) == nil)
    }

    @Test("the flawed half IS re-spelled without an attachment (control for the untouchable cases)")
    func flawedHalfControl() throws {
        let result = try #require(Self.respell(Self.voice(Self.flawed())))
        #expect(Self.tokens(result.slots) == ["C:1/4", "C:1/8", "C:1/8~", "C:3/8", "C:1/8"])
    }

    // MARK: Writing back (§4.3)

    @Test("graceNotesAfter on a span's chord leaves the span untouched")
    func graceNotesAfterLeaveSpanUntouched() throws {
        let grace = GraceChord(graceType: .grace8after, duration: .eighth, notes: [Note(pitch: 67, tpc: 15)])
        // Control: the same rhythm without after-graces is re-spelled.
        #expect(try #require(Self.respell(Self.voice(Self.flawed()))).slots.count == 5)
        #expect(Self.respell(Self.voice(Self.flawed { $0.graceNotesAfter = [grace] })) == nil)

        func merged(_ withGrace: Bool) -> Voice {
            var last = Self.chord(1, 4, pitch: 64, tieBack: true)
            if withGrace { last.graceNotesAfter = [grace] }
            return Self.voice([
                Self.note(1, 2), Self.note(1, 8, pitch: 62), Self.note(1, 8, pitch: 64, tieForward: true), .chord(last),
            ])
        }
        let control = try #require(Self.respell(merged(false)))
        #expect(Self.tokens(control.slots) == ["C:1/2", "C:1/8", "C:3/8"])
        #expect(Self.respell(merged(true)) == nil)
    }

    @Test("protected onset inside a rest run is a wall")
    func protectedOnsetInRestRun() throws {
        let voice = Self.voice([Self.rest(1, 4), Self.rest(1, 4), Self.note(1, 2)])
        #expect(Self.respell(voice, Self.facts(protected: [480])) == nil)
        let control = try #require(Self.respell(voice))
        #expect(Self.tokens(control.slots) == ["R:1/2", "C:1/2"])
    }

    @Test("tie into the next bar is kept on the last piece; tie from the previous bar on the head")
    func crossBarTies() throws {
        let voice = Self.voice([
            Self.note(1, 4), Self.note(1, 8, pitch: 62),
            Self.note(1, 2, pitch: 64, tieForward: true, tieBack: true), Self.note(1, 8, pitch: 65),
        ])
        let result = try #require(Self.respell(voice))
        let head = try #require(Self.chord(at: 2, in: result.slots))
        let tail = try #require(Self.chord(at: 3, in: result.slots))
        #expect(head.notes[0].tieBack == 1 && head.notes[0].tieForward == 1)
        #expect(tail.notes[0].tieBack == 1 && tail.notes[0].tieForward == 1)
    }

    @Test("a chain re-spelled into more pieces writes complete tie pairs on every note")
    func completeTiePairs() throws {
        let voice = Self.voice([
            Self.note(1, 8),
            .chord(Chord(duration: Self.duration(7, 8), notes: [
                Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18),
            ])),
        ])
        let policy = RhythmSpellingPolicy(dotLevel: .none, midBarSyncopations: .split)
        let result = try #require(Self.respell(voice, Self.facts(), policy))
        let chords = result.slots.compactMap { slot -> Chord? in
            if case let .chord(chord) = slot.element { chord } else { nil }
        }
        let chain = Array(chords.dropFirst())
        #expect(chain.count > 1)
        for (index, chord) in chain.enumerated() {
            for note in chord.notes {
                #expect((note.tieBack != nil) == (index > 0))
                #expect((note.tieForward != nil) == (index < chain.count - 1))
            }
        }
    }

    @Test("non-timed elements keep their identity and their tick")
    func untimedElementsKept() throws {
        let voice = Self.voice(Self.flawed(after: [.dynamic(Dynamic(subtype: "p", velocity: 49))]))
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["C:1/4", "C:1/8", "C:1/8~", "C:3/8", "other", "C:1/8"])
        #expect(result.slots[4].identity == .keep(voice.elements.eid(at: 3)))
    }

    @Test("a 3/8 chain of tied eighths merges into one dotted quarter")
    func tiedEighthChain() throws {
        let voice = Self.voice([
            Self.note(1, 8, tieForward: true), Self.note(1, 8, tieForward: true, tieBack: true),
            Self.note(1, 8, tieBack: true),
        ])
        let result = try #require(Self.respell(voice, Self.facts(meter: (3, 8))))
        #expect(Self.tokens(result.slots) == ["C:3/8"])
        #expect(result.slots[0].identity == .keep(voice.elements.eid(at: 0)))
    }
}

extension FormatRhythmsBarPlannerTests {
    // MARK: Rests, tuplets, bars

    @Test("a rest run stops at a tuplet edge and the tuplet is unchanged")
    func restRunStopsAtTuplet() throws {
        let third = Fraction(numerator: 1, denominator: 12)
        let member = VoiceElement.rest(duration: .fraction(third))
        let voice = Self.voice(
            [Self.rest(1, 4), Self.rest(1, 4), member, member, member, Self.rest(1, 8), Self.rest(1, 8)],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4)],
        )
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["R:1/2", "R:1/12", "R:1/12", "R:1/12", "R:1/4"])
        for (new, old) in [(1, 2), (2, 3), (3, 4)] {
            #expect(result.slots[new].identity == .keep(voice.elements.eid(at: old)))
        }
        let tuplet = try #require(result.tupletSlots.first)
        #expect(result.tupletSlots.count == 1)
        #expect(tuplet.identity == .keep(voice.tuplets.eid(at: 0)))
        #expect(tuplet.tuplet.first == .index(1) && tuplet.tuplet.last == .index(3))
        #expect(tuplet.tuplet.normalNotes == 2 && tuplet.tuplet.actualNotes == 3)
    }

    @Test("a rest run filling the bar becomes a measure rest; an existing measure rest is never rewritten")
    func measureRests() throws {
        let result = try #require(Self.respell(Self.voice([
            Self.rest(1, 4), Self.rest(1, 4), Self.rest(1, 4), Self.rest(1, 4),
        ])))
        #expect(Self.tokens(result.slots) == ["R:measure"])
        #expect(result.slots[0].identity == .fresh)
        #expect(Self.respell(Self.voice([.rest(duration: .measure)])) == nil)
    }

    struct AttributedRest: CustomTestStringConvertible, Sendable {
        let name: String
        let attribute: @Sendable (inout Chord) -> Void
        var testDescription: String {
            name
        }
    }

    static let attributedRests: [AttributedRest] = [
        AttributedRest(name: "hidden") { $0.elementProperties.visible = false },
        AttributedRest(name: "colored") { $0.elementProperties.color = ScoreColor(red: 255, green: 0, blue: 0) },
        AttributedRest(name: "spanner") { $0.spanners = [Spanner(kind: .slur, rawType: "Slur")] },
        AttributedRest(name: "grace before") {
            $0.graceNotesBefore = [beforeGrace]
        },
        AttributedRest(name: "grace after") {
            $0.graceNotesAfter = [afterGrace]
        },
        AttributedRest(name: "preserved markup") { $0.preservedMarkup = [PreservedXML(name: "Unknown")] },
    ]

    @Test("a rest that carries something is a wall: kept exactly as written", arguments: attributedRests)
    func attributedRestIsAWall(_ example: AttributedRest) throws {
        var marked = Chord(duration: Self.duration(1, 4), notes: [])
        example.attribute(&marked)
        let voice = Self.voice([Self.rest(1, 4), Self.rest(1, 4), .chord(marked), Self.rest(1, 4)])
        let result = try #require(Self.respell(voice))
        // The two bare rests before it merge; the marked rest is untouched and keeps its identifier.
        #expect(Self.tokens(result.slots) == ["R:1/2", "R:1/4", "R:1/4"])
        #expect(result.slots[1].identity == .keep(voice.elements.eid(at: 2)))
        #expect(result.slots[1].element == .chord(marked))
    }

    @Test("the same rest run without an attribute is re-spelled (control for the wall cases)")
    func bareRestRunControl() throws {
        let voice = Self.voice([Self.rest(1, 4), Self.rest(1, 4), Self.rest(1, 4), Self.rest(1, 4)])
        #expect(try Self.tokens(#require(Self.respell(voice)).slots) == ["R:measure"])
    }

    @Test("pickup: a rest run filling a pickup stays typed and right-aligned")
    func pickupRests() throws {
        let half = try #require(Self.respell(
            Self.voice([Self.rest(1, 4), Self.rest(1, 4)]), Self.facts(barTicks: 960, pickup: true),
        ))
        #expect(Self.tokens(half.slots) == ["R:1/2"])
        let quarter = try #require(Self.respell(
            Self.voice([Self.rest(1, 8), Self.rest(1, 8)]), Self.facts(barTicks: 480, pickup: true),
        ))
        #expect(Self.tokens(quarter.slots) == ["R:1/4"])
        #expect(Self.respell(Self.voice([Self.rest(1, 4)]), Self.facts(barTicks: 480, pickup: true)) == nil)
    }

    @Test("pickup: positions are right-aligned against the nominal bar")
    func pickupNotes() throws {
        let single = try #require(Self.respell(
            Self.voice([Self.note(5, 8)]), Self.facts(barTicks: 1200, pickup: true),
        ))
        #expect(Self.tokens(single.slots) == ["C:1/8~", "C:1/2"])
        let chain = try #require(Self.respell(
            Self.voice([Self.note(1, 8, tieForward: true), Self.note(1, 4, tieBack: true)]),
            Self.facts(barTicks: 720, pickup: true),
        ))
        #expect(Self.tokens(chain.slots) == ["C:3/8"])
    }

    @Test("window: a span crossing the window edge is left alone")
    func windowEdges() {
        let voice = Self.voice(Self.thirdBarFlaw)
        #expect(Self.respell(voice, Self.facts(window: 0 ..< 1200)) == nil)
        #expect(Self.respell(voice, Self.facts(window: 960 ..< 1920)) == nil)
        #expect(Self.respell(voice, Self.facts(window: 720 ..< 1680)) != nil)
        #expect(Self.respell(voice, Self.facts(window: 0 ..< 1920)) != nil)
    }

    @Test("nothing to change returns nil")
    func nothingToChange() {
        let tidy = Self.voice([Self.note(1, 4), Self.note(1, 4, pitch: 62), Self.note(1, 2, pitch: 64)])
        #expect(Self.respell(tidy) == nil)
        #expect(Self.respell(Self.voice([])) == nil)
    }

    @Test("a 1/3-whole untied chord and a 1/7 rest are carried as written, never shortened")
    func unspellableSpansAreCarried() {
        #expect(Self.respell(Self.voice([Self.note(1, 3)])) == nil)
        #expect(Self.respell(Self.voice([Self.rest(1, 7)])) == nil)
    }

    @Test("a split chord's fresh tail copies the head's stem and beam flags")
    func splitTailCopiesBeamVisible() throws {
        var hidden = Self.chord(3, 8, pitch: 64)
        hidden.beamVisible = false
        hidden.stemVisible = false
        let voice = Self.voice([
            Self.note(1, 4), Self.note(1, 8, pitch: 62), .chord(hidden), Self.note(1, 4, pitch: 65),
        ])
        let result = try #require(Self.respell(voice))
        let tail = try #require(Self.chord(at: 3, in: result.slots))
        #expect(tail.beamVisible == false)
        #expect(tail.stemVisible == false)
    }
}
