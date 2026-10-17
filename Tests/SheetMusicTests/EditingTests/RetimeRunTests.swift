@testable import SheetMusicCore
import SheetMusicEditWire
import Testing

/// `RetimeRun` through `ScoreEditSession` — the path a host takes: intent, planner, command, the session's repair
/// passes, one undo step.
@Suite("RetimeRun")
struct RetimeRunTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int, measure: Int = 0, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func chord(
        _ pitch: Int, _ tpc: Int, _ duration: NoteDuration,
        lyric: Lyric? = nil, tieBack: Bool = false, tieForward: Bool = false,
    ) -> VoiceElement {
        var note = Note(pitch: pitch, tpc: tpc)
        note.tieBack = tieBack ? 1 : nil
        note.tieForward = tieForward ? 1 : nil
        return .chord(Chord(duration: duration, notes: [note], lyrics: lyric.map { [$0] } ?? []))
    }

    /// Two 4/4 bars. Bar 0 is `[ts, C5 q, D5 q, E5 q, F5 8. "lu", <marks>, G5 16 "lu"]`: the pair this suite re-times
    /// starts at element 4, tick 1440, and its sixteenth sits at 1800 until it moves to 1680. `marks` go between the
    /// two, which makes the sixteenth element `5 + marks.count`. Bar 1 is `[G5 q, r q, r h]` — the chord a mark
    /// reaching past the run ends on, at staff tick 1920.
    private static func dottedPair(between marks: [VoiceElement] = []) -> Score {
        var bar0: [VoiceElement] = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            chord(72, 14, .quarter), chord(74, 16, .quarter), chord(76, 18, .quarter),
            chord(77, 13, NoteDuration.eighth.dotted(1), lyric: Lyric(text: "lu")),
        ]
        bar0 += marks
        bar0.append(chord(79, 15, .sixteenth, lyric: Lyric(text: "lu")))
        let bar1: [VoiceElement] = [chord(79, 15, .quarter), .rest(duration: .quarter), .rest(duration: .half)]
        let staff = Staff(measures: [
            Measure(voices: [Voice(elements: bar0)]), Measure(voices: [Voice(elements: bar1)]),
        ])
        return Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
    }

    private static let dotted = slot(4)
    private static let sixteenth = slot(5)
    private static let nextBar = slot(0, measure: 1)
    private static let twoEighths = EditIntent.retimeRun(at: dotted, durations: [.eighth, .eighth])

    private static func chordValue(at id: VoiceElementID, in score: Score) -> Chord? {
        guard case let .chord(chord)? = score[id] else { return nil }
        return chord
    }

    /// `score` with a second voice in bar 0.
    private static func withLowerVoice(_ elements: [VoiceElement], in score: Score) -> Score {
        var score = score
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices.append(Voice(elements: elements))
            }
        }
        return score
    }

    /// Where the spanner begun at `id` ends, in staff ticks — a slur on the chord there, or the line whose begin
    /// marker is the element there — read the way playback and layout read `<next>`: the begin's onset, plus whole
    /// bars, plus the fraction (`HairpinRamps.computeEndTick`). Both bars are 1920 ticks long.
    private static func spannerEnd(at id: VoiceElementID, in score: Score) -> Int? {
        let spanner: Spanner?
        switch score[id] {
        case let .chord(chord)?: spanner = chord.spanners.first
        case let .spanner(line)?: spanner = line
        default: spanner = nil
        }
        guard let spanner, let onset = score.absoluteTick(of: id) else { return nil }
        let fraction = spanner.nextFractionsOffset?.ticks(division: 480) ?? 0
        return onset + spanner.nextMeasuresOffset * 1920 + fraction
    }

    /// Where bar 0's system lane holds the staff or system text reading `text`.
    private static func textPosition(of text: String, in score: Score) -> MeasurePosition? {
        guard let lane = score.systemMeasures.first else { return nil }
        for positioned in lane.elements {
            if case let .staffText(mark) = positioned.element, mark.text == text { return positioned.position }
        }
        return nil
    }

    /// Where bar 0's system lane holds its tempo mark.
    private static func tempoPosition(in score: Score) -> MeasurePosition? {
        guard let lane = score.systemMeasures.first else { return nil }
        for positioned in lane.elements {
            if case .tempo = positioned.element { return positioned.position }
        }
        return nil
    }

    /// The sixteenth's lane position before the re-time (tick 1800) and after it (tick 1680).
    private static let oldSixteenthBeat = MeasurePosition(numerator: 15, denominator: 16)
    private static let newSixteenthBeat = MeasurePosition(numerator: 7, denominator: 8)

    /// Where the verse-0 melisma on `id` ends, in staff ticks: `Lyric.ticks` past the syllable's own onset.
    private static func melismaEnd(on id: VoiceElementID, in score: Score) -> Int? {
        guard let ticks = chordValue(at: id, in: score)?.lyrics.first?.ticks, let onset = score.absoluteTick(of: id)
        else { return nil }
        return onset + ticks
    }

    @Test func `a dotted eighth and a sixteenth become two eighths, keeping pitches and lyrics`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        let before = session.score
        #expect(session.apply(Self.twoEighths))
        let first = Self.chordValue(at: Self.dotted, in: session.score)
        let second = Self.chordValue(at: Self.sixteenth, in: session.score)
        #expect(first?.duration == .eighth)
        #expect(second?.duration == .eighth)
        #expect(first?.notes.map(\.pitch) == [77])
        #expect(first?.notes.map(\.tpc) == [13])
        #expect(second?.notes.map(\.pitch) == [79])
        #expect(second?.notes.map(\.tpc) == [15])
        #expect(first?.lyrics.map(\.text) == ["lu"])
        #expect(second?.lyrics.map(\.text) == ["lu"])
        #expect(session.score.absoluteTick(of: Self.sixteenth) == 1680)
        let voice = VoiceRef(Self.dotted)
        #expect(session.score[voice: voice]?.elements.count == before[voice: voice]?.elements.count)
        // One undo step takes the whole edit back.
        #expect(session.undo())
        #expect(session.score == before)
    }

    @Test func `a slur reaching into the run from before it keeps both ends`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        let anchor = Self.slot(3)
        #expect(session.apply(.setSlur(over: VoiceElementRange(start: anchor, end: Self.sixteenth))))
        // The probe read before the edit: it finds the slur ending on the sixteenth, so the same reading afterwards
        // says something.
        #expect(Self.spannerEnd(at: anchor, in: session.score) == 1800)
        #expect(session.apply(Self.twoEighths))
        #expect(session.score.absoluteTick(of: Self.sixteenth) == 1680)
        #expect(Self.spannerEnd(at: anchor, in: session.score) == session.score.absoluteTick(of: Self.sixteenth))
        #expect(Self.chordValue(at: anchor, in: session.score)?.spanners.count == 1)
    }

    @Test func `a slur starting on the run and ending after it keeps both ends`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        #expect(session.apply(.setSlur(over: VoiceElementRange(start: Self.sixteenth, end: Self.nextBar))))
        #expect(Self.spannerEnd(at: Self.sixteenth, in: session.score) == 1920)
        #expect(session.apply(Self.twoEighths))
        // The begin moved a sixteenth earlier; the end is still the next bar's first chord.
        #expect(session.score.absoluteTick(of: Self.sixteenth) == 1680)
        #expect(Self.spannerEnd(at: Self.sixteenth, in: session.score) == session.score.absoluteTick(of: Self.nextBar))
    }

    @Test func `a dynamic between the two chords stays before the second chord`() {
        let mezzoForte = VoiceElement.dynamic(Dynamic(subtype: "mf", velocity: 80))
        let session = ScoreEditSession(score: Self.dottedPair(between: [mezzoForte]))
        let mark = Self.slot(5)
        let second = Self.slot(6)
        #expect(session.apply(Self.twoEighths))
        guard case let .dynamic(dynamic)? = session.score[mark] else {
            Issue.record("expected the dynamic still at element 5, got \(String(describing: session.score[mark]))")
            return
        }
        #expect(dynamic.subtype == "mf")
        #expect(Self.chordValue(at: second, in: session.score)?.duration == .eighth)
        #expect(session.score.absoluteTick(of: second) == 1680)
        #expect(session.score.absoluteTick(of: mark) == 1680)
    }

    @Test func `a tie into the first chord and out of the last survive`() {
        var score = Self.dottedPair()
        score[Self.slot(3)] = Self.chord(77, 13, .quarter, tieForward: true)
        score[Self.dotted] = Self.chord(77, 13, NoteDuration.eighth.dotted(1), lyric: Lyric(text: "lu"), tieBack: true)
        score[Self.sixteenth] = Self.chord(79, 15, .sixteenth, lyric: Lyric(text: "lu"), tieForward: true)
        score[Self.nextBar] = Self.chord(79, 15, .quarter, tieBack: true)
        let session = ScoreEditSession(score: score)
        #expect(session.apply(Self.twoEighths))
        let after = session.score
        #expect(Self.chordValue(at: Self.dotted, in: after)?.duration == .eighth)
        #expect(Self.chordValue(at: Self.slot(3), in: after)?.notes.first?.tieForward == 1)
        #expect(Self.chordValue(at: Self.dotted, in: after)?.notes.first?.tieBack == 1)
        #expect(Self.chordValue(at: Self.sixteenth, in: after)?.notes.first?.tieForward == 1)
        #expect(Self.chordValue(at: Self.nextBar, in: after)?.notes.first?.tieBack == 1)
    }

    @Test func `a melisma ending after the run still ends on the same chord`() {
        var score = Self.dottedPair()
        // The sixteenth's syllable holds into the next bar's G5 (1800 → 1920): a melisma that starts in the run…
        score[Self.sixteenth] = Self.chord(79, 15, .sixteenth, lyric: Lyric(text: "lu", ticks: 120))
        // …and the E5 quarter's holds onto the sixteenth (960 → 1800): one that ends in it.
        score[Self.slot(3)] = Self.chord(76, 18, .quarter, lyric: Lyric(text: "la", ticks: 840))
        let session = ScoreEditSession(score: score)
        #expect(session.apply(Self.twoEighths))
        let after = session.score
        #expect(Self.melismaEnd(on: Self.sixteenth, in: after) == after.absoluteTick(of: Self.nextBar))
        #expect(Self.melismaEnd(on: Self.slot(3), in: after) == after.absoluteTick(of: Self.sixteenth))
        #expect(Self.chordValue(at: Self.sixteenth, in: after)?.lyrics.first?.ticks == 240)
        #expect(Self.chordValue(at: Self.slot(3), in: after)?.lyrics.first?.ticks == 720)
    }

    @Test func `a different total is refused as insufficient room`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        let before = session.score
        #expect(!session.apply(.retimeRun(at: Self.dotted, durations: [.eighth, .quarter])))
        #expect(session.lastRefusal?.reason == .insufficientRoom(neededTicks: 720, availableTicks: 480))
        #expect(session.score == before)
    }

    @Test func `a tuplet member is refused`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        // The sixteenth becomes a 3:2 group, so the run's first member is free and its second is not — and the
        // tuplet is refused before the totals (360 + 40 against 480) are compared.
        #expect(session.apply(.createTuplet(at: Self.sixteenth, actualNotes: 3, normalNotes: 2)))
        let before = session.score
        #expect(!session.apply(Self.twoEighths))
        #expect(session.lastRefusal?.reason == .insideTuplet(at: Self.sixteenth))
        #expect(session.score == before)
    }

    @Test func `a run longer than what remains in the bar is refused`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        let before = session.score
        // Two chords remain in bar 0 from the dotted eighth. Three durations totaling those two plus the next bar's
        // quarter (960 ticks) would apply if the run were allowed to cross the barline.
        #expect(!session.apply(.retimeRun(at: Self.dotted, durations: [.quarter, .eighth, .eighth])))
        #expect(session.lastRefusal?.reason == .targetNotFound(Self.dotted))
        #expect(session.score == before)
    }

    @Test func `the same durations apply nothing`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        let before = session.score
        #expect(!session.apply(.retimeRun(at: Self.dotted, durations: [NoteDuration.eighth.dotted(1), .sixteenth])))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score == before)
        #expect(!session.canUndo)
    }

    @Test func `another voice of the staff is untouched`() {
        // A second voice under the pair, slurred from its quarter (960) to its second eighth (1680). Every write the
        // command makes is addressed in the run's own voice, so this holds by construction; it is pinned because a
        // staff shared by two singers relies on it, not because a mutation of the voice filter reaches it.
        let score = Self.withLowerVoice([
            .rest(duration: .half), Self.chord(60, 14, .quarter),
            Self.chord(62, 16, .eighth), Self.chord(64, 18, .eighth),
        ], in: Self.dottedPair())
        let session = ScoreEditSession(score: score)
        let slurred = VoiceElementRange(start: Self.slot(1, voice: 1), end: Self.slot(3, voice: 1))
        #expect(session.apply(.setSlur(over: slurred)))
        let lower = VoiceRef(staff: Self.staff0, measureIndex: 0, voiceIndex: 1)
        let before = session.score[voice: lower]
        #expect(session.apply(Self.twoEighths))
        #expect(session.score.absoluteTick(of: Self.sixteenth) == 1680)
        #expect(session.score[voice: lower] == before)
    }

    @Test func `another voice's slur at the run's element index leaves the run's own slur alone`() {
        // Voice 1 is eight eighths, slurred from element 5 (1200) to element 6 (1440) — the same element index as the
        // run's sixteenth, with a different extent. A spanner walk that did not keep to the run's voice would
        // address that record at the sixteenth and write voice 1's extent over the sixteenth's own slur.
        var lower = [VoiceElement](repeating: .rest(duration: .eighth), count: 5)
        lower += [Self.chord(60, 14, .eighth), Self.chord(62, 16, .eighth), .rest(duration: .eighth)]
        let session = ScoreEditSession(score: Self.withLowerVoice(lower, in: Self.dottedPair()))
        #expect(session.apply(.setSlur(over: VoiceElementRange(start: Self.sixteenth, end: Self.nextBar))))
        let lowerSlur = VoiceElementRange(start: Self.slot(5, voice: 1), end: Self.slot(6, voice: 1))
        #expect(session.apply(.setSlur(over: lowerSlur)))
        #expect(Self.spannerEnd(at: Self.sixteenth, in: session.score) == 1920)
        #expect(session.apply(Self.twoEighths))
        #expect(Self.spannerEnd(at: Self.sixteenth, in: session.score) == session.score.absoluteTick(of: Self.nextBar))
        #expect(Self.spannerEnd(at: Self.slot(5, voice: 1), in: session.score) == 1440)
    }

    @Test func `a hairpin beginning before the sixteenth keeps both ends`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        let over = VoiceElementRange(start: Self.sixteenth, end: Self.nextBar)
        #expect(session.apply(.setHairpin(over: over, subtype: .crescendo)))
        // The begin marker goes in before the sixteenth, which becomes element 6; the hairpin ends where the next
        // bar's first chord does, at the onset of the rest after it (2400).
        let marker = Self.slot(5)
        let shifted = Self.slot(6)
        let afterNext = Self.slot(1, measure: 1)
        guard case .spanner? = session.score[marker] else {
            Issue.record("expected the begin marker at element 5, got \(String(describing: session.score[marker]))")
            return
        }
        #expect(Self.spannerEnd(at: marker, in: session.score) == 2400)
        #expect(session.apply(Self.twoEighths))
        #expect(session.score.absoluteTick(of: shifted) == 1680)
        #expect(session.score.absoluteTick(of: marker) == session.score.absoluteTick(of: shifted))
        #expect(Self.spannerEnd(at: marker, in: session.score) == session.score.absoluteTick(of: afterNext))
    }

    @Test func `a rest in the run stays a rest at its new length`() {
        var score = Self.dottedPair()
        score[Self.sixteenth] = .rest(duration: .sixteenth)
        let session = ScoreEditSession(score: score)
        #expect(session.apply(Self.twoEighths))
        let rest = Self.chordValue(at: Self.sixteenth, in: session.score)
        #expect(rest?.notes.isEmpty == true)
        #expect(rest?.duration == .eighth)
        #expect(Self.chordValue(at: Self.dotted, in: session.score)?.duration == .eighth)
    }

    @Test func `a staff text on the sixteenth moves to the sixteenth's new onset`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        #expect(session.apply(.setStaffText(anchor: Self.sixteenth, text: "rit.", isSystemText: false)))
        #expect(Self.textPosition(of: "rit.", in: session.score) == Self.oldSixteenthBeat)
        let before = session.score
        #expect(session.apply(Self.twoEighths))
        #expect(Self.textPosition(of: "rit.", in: session.score) == Self.newSixteenthBeat)
        // The move rides the same composite: one undo takes the chords and the text back together.
        #expect(session.undo())
        #expect(session.score == before)
    }

    @Test func `a staff text stays where another voice of the staff starts an element`() {
        // Voice 1 starts a sixteenth at 1800, the same tick as the run's sixteenth: the text may be that one's.
        let lower: [VoiceElement] = [
            .rest(duration: .half), .rest(duration: .quarter),
            .rest(duration: NoteDuration.eighth.dotted(1)), Self.chord(60, 14, .sixteenth),
        ]
        let session = ScoreEditSession(score: Self.withLowerVoice(lower, in: Self.dottedPair()))
        #expect(session.apply(.setStaffText(anchor: Self.sixteenth, text: "rit.", isSystemText: false)))
        #expect(session.apply(Self.twoEighths))
        #expect(session.score.absoluteTick(of: Self.sixteenth) == 1680)
        #expect(Self.textPosition(of: "rit.", in: session.score) == Self.oldSixteenthBeat)
    }

    @Test func `a tempo mark and a system text at the sixteenth's onset stay`() {
        let session = ScoreEditSession(score: Self.dottedPair())
        #expect(session.apply(.setTempo(anchor: Self.sixteenth, marking: SetTempo.Marking(beatsPerSecond: 2))))
        #expect(session.apply(.setStaffText(anchor: Self.sixteenth, text: "Fine", isSystemText: true)))
        #expect(Self.tempoPosition(in: session.score) == Self.oldSixteenthBeat)
        #expect(Self.textPosition(of: "Fine", in: session.score) == Self.oldSixteenthBeat)
        #expect(session.apply(Self.twoEighths))
        #expect(session.score.absoluteTick(of: Self.sixteenth) == 1680)
        #expect(Self.tempoPosition(in: session.score) == Self.oldSixteenthBeat)
        #expect(Self.textPosition(of: "Fine", in: session.score) == Self.oldSixteenthBeat)
    }

    @Test func `the intent round-trips through the wire codec at index 91`() throws {
        let intent = EditIntent.retimeRun(
            at: Self.dotted,
            durations: [.eighth, NoteDuration.eighth.dotted(1), .fraction(Fraction(numerator: 1, denominator: 12))],
        )
        let bytes = EditIntentCodec.encode(intent)
        // `varint(payloadLength)` then `varint(caseIndex)`: this payload is short enough for both to be one byte.
        #expect(bytes[1] == 91)
        #expect(try EditIntentCodec.decode(bytes) == intent)
    }
}
