@testable import SheetMusicCore
import Testing

@Suite("RemoveSlur")
struct RemoveSlurTests {
    private static func slot(_ index: Int) -> VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: index,
        )
    }

    private static func fixture(_ voice: Voice) -> Score {
        ScoreEditor(score: Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"),
            staves: [Staff(measures: [Measure(voices: [voice])])],
        )])).score
    }

    @Test(
        "ordinal selects only slurs, including hidden ones, on chords and rests",
        arguments: [false, true],
        [1, 2],
    )
    func chordOrdinal(_ rest: Bool, _ ordinal: Int) throws {
        let notes: ChordNotes = rest ? [] : [Note(pitch: 60, tpc: 14)]
        let spanners: [Spanner] = [
            Spanner(kind: .hairpin, rawType: "HairPin"),
            Spanner(kind: .slur, rawType: "Slur", visible: false),
            Spanner(
                kind: .slur,
                rawType: "Slur",
                nextMeasuresOffset: 1,
                preservedMarkup: [PreservedXML(name: "custom", text: "second")],
            ),
            Spanner(kind: .pedal, rawType: "Pedal"),
            Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 2),
        ]
        var score = Self.fixture(Voice(elements: [
            .chord(Chord(duration: .quarter, notes: notes, spanners: spanners)),
        ]))
        let before = score
        let inverse = try RemoveSlur(.chord(anchor: Self.slot(0), ordinal: ordinal)).apply(to: &score)
        let survivors: [Spanner] = ordinal == 1
            ? [spanners[0], spanners[1], spanners[3], spanners[4]]
            : [spanners[0], spanners[1], spanners[2], spanners[3]]
        guard case var .chord(expectedChord) = before[Self.slot(0)] else {
            Issue.record("expected chord/rest"); return
        }
        expectedChord.spanners = survivors
        var expected = before
        expected[Self.slot(0)] = .chord(expectedChord)
        #expect(score == expected)
        #expect(score.stableFingerprint != before.stableFingerprint)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
    }

    @Test("with two slurs only the second is removed")
    func secondOfTwo() throws {
        let first = Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 1)
        let second = Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 2)
        var score = Self.fixture(Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)], spanners: [first, second])),
        ]))
        let before = score
        let inverse = try RemoveSlur(.chord(anchor: Self.slot(0), ordinal: 1)).apply(to: &score)
        guard case let .chord(chord) = score[Self.slot(0)] else { Issue.record("expected chord"); return }
        #expect(chord.spanners == [first])
        #expect(score.stableFingerprint != before.stableFingerprint)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
    }

    @Test("standalone removal remaps tuplets and shifts slots without changing time offsets")
    func standaloneIndices() throws {
        let chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        let pedal = Spanner(
            kind: .pedal,
            rawType: "Pedal",
            nextMeasuresOffset: 1,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
        )
        var score = Self.fixture(Voice(elements: [
            .chord(chord), .spanner(Spanner(kind: .slur, rawType: "Slur")),
            .chord(chord), .chord(chord), .spanner(pedal),
        ], tuplets: [Tuplet(normalNotes: 3, actualNotes: 2, startIndex: 2, endIndex: 3)]))
        let before = score
        let oldVoice = before.parts[0].staves[0].measures[0].voices[0]
        let inverse = try RemoveSlur(.voice(Self.slot(1))).apply(to: &score)
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        #expect(voice.elements == [
            oldVoice.elements[0],
            oldVoice.elements[2],
            oldVoice.elements[3],
            oldVoice.elements[4],
        ])
        #expect(voice.tuplets == [Tuplet(normalNotes: 3, actualNotes: 2, startIndex: 1, endIndex: 2)])
        #expect(score[Self.slot(3)] == .spanner(pedal))
        var expected = before
        expected.parts[0].staves[0].measures[0].voices[0] = voice
        #expect(score == expected)
        #expect(score.stableFingerprint != before.stableFingerprint)
        let removed = score
        let redo = try inverse.apply(to: &score)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
        _ = try redo.apply(to: &score)
        #expect(score == removed)
    }

    @Test("invalid ordinals, owners, storage shapes and kinds are refused atomically")
    func individualRefusals() {
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
                spanners: [Spanner(kind: .slur, rawType: "Slur")],
            )),
            .spanner(Spanner(kind: .pedal, rawType: "Pedal")),
            .barLine(BarLine()), .rest(duration: .quarter),
        ])
        let cases: [(SlurID, EditRefusal.Reason)] = [
            (.chord(anchor: Self.slot(0), ordinal: -1), .noSpannerAtLocation(Self.slot(0))),
            (.chord(anchor: Self.slot(0), ordinal: 1), .noSpannerAtLocation(Self.slot(0))),
            (.chord(anchor: Self.slot(3), ordinal: 0), .noSpannerAtLocation(Self.slot(3))),
            (.chord(anchor: Self.slot(4), ordinal: 0), .targetNotFound(Self.slot(4))),
            (.voice(Self.slot(4)), .targetNotFound(Self.slot(4))),
            (.chord(anchor: Self.slot(2), ordinal: 0), .wrongElementKind(at: Self.slot(2), expected: .chordOrRest)),
            (.voice(Self.slot(0)), .wrongElementKind(at: Self.slot(0), expected: .spanner)),
            (.voice(Self.slot(1)), .noSpannerAtLocation(Self.slot(1))),
        ]
        for (id, reason) in cases {
            var score = Self.fixture(voice)
            let before = score
            let command = RemoveSlur(id)
            #expect(command.affectedLocation == id.anchor)
            let error = #expect(throws: SheetMusicError.self) { _ = try command.apply(to: &score) }
            guard case let .invalidEdit(refusal)? = error else { Issue.record("expected refusal"); continue }
            #expect(refusal.reason == reason)
            #expect(refusal.operation == "RemoveSlur")
            #expect(score == before)
            #expect(score.stableFingerprint == before.stableFingerprint)
        }
    }
}

@Suite("RemoveSpanner")
struct RemoveSpannerTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    private static func operation(of error: SheetMusicError?) -> String? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.operation
    }

    @Test("removes a line spanner element, shifting the later indices back, and undo restores them")
    func removesLineSpanner() throws {
        var score = ScoreEditor(score: EditingFixtures.parityFixture()).score
        let plain = score
        _ = try SetHairpin(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)), subtype: .crescendo)
            .apply(to: &score)
        let written = score
        let inverse = try RemoveSpanner(at: Self.slot(0, 1), kind: .hairpin).apply(to: &score)
        #expect(score == plain)
        _ = try inverse.apply(to: &score)
        #expect(score == written)
    }

    @Test("removes every slur entry of the chord, leaving the chord's other spanners and the chord itself alone")
    func removesSlurs() throws {
        var score = ScoreEditor(score: EditingFixtures.parityFixture()).score
        guard case var .chord(head) = score.parts[0].staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected the C4"); return
        }
        // A non-slur entry sits between the two slurs: the removal filters by kind, it does not empty the array.
        let survivor = Spanner(kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: 2)
        head.spanners = [
            Spanner(kind: .slur, rawType: "Slur"),
            survivor,
            Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 1),
        ]
        score.parts[0].staves[0].measures[0].voices[0].elements[1] = .chord(head)
        _ = try RemoveSpanner(at: Self.slot(0, 1), kind: .slur).apply(to: &score)
        guard case let .chord(stripped) = score.parts[0].staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected the C4"); return
        }
        #expect(stripped.spanners == [survivor])
        #expect(stripped.notes == head.notes)
        #expect(stripped.duration == head.duration)
    }

    @Test("the other staff and the other bars are untouched")
    func siblingsUntouched() throws {
        var score = ScoreEditor(score: EditingFixtures.parityFixture()).score
        _ = try SetPedal(over: VoiceElementRange(start: Self.slot(2, 0), end: Self.slot(2, 1))).apply(to: &score)
        let before = score
        _ = try RemoveSpanner(at: Self.slot(2, 0), kind: .pedal).apply(to: &score)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[0 ..< 2] == before.parts[0].staves[0].measures[0 ..< 2])
    }

    @Test("a mismatched kind, a chord with no slur, a non-spanner element and a missing element are refused")
    func refusals() throws {
        var score = ScoreEditor(score: EditingFixtures.parityFixture()).score
        _ = try SetPedal(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2))).apply(to: &score)
        let written = score
        let wrongKind = #expect(throws: SheetMusicError.self) {
            _ = try RemoveSpanner(at: Self.slot(0, 1), kind: .hairpin).apply(to: &score)
        }
        #expect(Self.reason(of: wrongKind) == .noSpannerAtLocation(Self.slot(0, 1)))
        // `SpannerPlacement` serves eleven commands; the refusal has to name this one.
        #expect(Self.operation(of: wrongKind) == "RemoveSpanner")
        let noSlur = #expect(throws: SheetMusicError.self) {
            _ = try RemoveSpanner(at: Self.slot(0, 2), kind: .slur).apply(to: &score)
        }
        #expect(Self.reason(of: noSlur) == .noSpannerAtLocation(Self.slot(0, 2)))
        let notASpanner = #expect(throws: SheetMusicError.self) {
            _ = try RemoveSpanner(at: Self.slot(0, 0), kind: .pedal).apply(to: &score)
        }
        #expect(Self.reason(of: notASpanner) == .wrongElementKind(at: Self.slot(0, 0), expected: .spanner))
        #expect(throws: SheetMusicError.self) {
            _ = try RemoveSpanner(at: Self.slot(9, 0), kind: .pedal).apply(to: &score)
        }
        #expect(score == written)
    }
}
