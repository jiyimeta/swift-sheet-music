@testable import SheetMusicCore
import Testing

@Suite("FormatRhythms")
struct FormatRhythmsTests {
    private typealias Bars = FormatRhythmsBarPlannerTests

    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let staff1 = StaffAddress(partIndex: 0, staffIndexInPart: 1)
    private static let policy = RhythmSpellingPolicy.default

    private static func slot(
        _ staff: StaffAddress = staff0, measure: Int = 0, voice: Int = 0, element: Int,
    ) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    /// Two tied quarters followed by a half rest — a bar that formats to a half note and a half rest.
    private static func tiedPair(pitch: Int = 60) -> [VoiceElement] {
        [
            Bars.note(1, 4, pitch: pitch, tieForward: true), Bars.note(1, 4, pitch: pitch, tieBack: true),
            Bars.rest(1, 2),
        ]
    }

    private static func score(_ staves: [[Measure]]) -> Score {
        Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "piano"), staves: IdentifiedArray(staves.map { Staff(measures: $0) }),
        )], systemMeasures: IdentifiedArray(staves[0].map { _ in SystemMeasure() }))
    }

    private static func bar(_ voices: [VoiceElement]...) -> Measure {
        Measure(voices: voices.map { Voice(elements: $0) })
    }

    private static func durations(_ score: Score, _ staff: StaffAddress = staff0, measure: Int = 0, voice: Int = 0)
        -> [NoteDuration]
    {
        score[voice: VoiceRef(staff: staff, measureIndex: measure, voiceIndex: voice)]?.elements.values.compactMap {
            switch $0 {
            case let .chord(chord): chord.duration
            default: nil
            }
        } ?? []
    }

    private static func reason(_ body: () throws -> some Any) -> EditRefusal.Reason? {
        do {
            _ = try body()
            return nil
        } catch let SheetMusicError.invalidEdit(refusal) {
            return refusal.reason
        } catch {
            return nil
        }
    }

    private static let half = Bars.duration(1, 2)

    @Test("score scope rewrites every staff and voice")
    func scoreScope() throws {
        var score = Self.score([
            [Self.bar(Self.tiedPair(), Self.tiedPair(pitch: 64))],
            [Self.bar(Self.tiedPair(pitch: 48))],
        ])
        _ = try FormatRhythms(scope: .score, policy: Self.policy).apply(to: &score)
        #expect(Self.durations(score, Self.staff0, voice: 0) == [Self.half, Self.half])
        #expect(Self.durations(score, Self.staff0, voice: 1) == [Self.half, Self.half])
        #expect(Self.durations(score, Self.staff1, voice: 0) == [Self.half, Self.half])
    }

    @Test("measure scope touches only that staff-bar")
    func measureScope() throws {
        var score = Self.score([
            [Self.bar(Self.tiedPair()), Self.bar(Self.tiedPair())],
            [Self.bar(Self.tiedPair()), Self.bar(Self.tiedPair())],
        ])
        let before = score
        _ = try FormatRhythms(scope: .measure(staff: Self.staff0, measureIndex: 1), policy: Self.policy)
            .apply(to: &score)
        #expect(Self.durations(score, Self.staff0, measure: 1) == [Self.half, Self.half])
        #expect(Self.durations(score, Self.staff0, measure: 0) == Self.durations(before, Self.staff0, measure: 0))
        #expect(Self.durations(score, Self.staff1, measure: 0) == Self.durations(before, Self.staff1, measure: 0))
        #expect(Self.durations(score, Self.staff1, measure: 1) == Self.durations(before, Self.staff1, measure: 1))
    }

    @Test("span crossing the range edge is left alone")
    func rangeEdge() throws {
        let score = Self.score([[Self.bar(Self.tiedPair())]])
        let firstOnly = VoiceElementRange(start: Self.slot(element: 0), end: Self.slot(element: 0))
        let ids = EIDAllocator()
        #expect(try FormatRhythms(scope: .range(firstOnly), policy: Self.policy).plan(in: score, ids: ids) == nil)

        let wholeSpan = VoiceElementRange(start: Self.slot(element: 0), end: Self.slot(element: 1))
        var formatted = score
        _ = try FormatRhythms(scope: .range(wholeSpan), policy: Self.policy).apply(to: &formatted)
        #expect(Self.durations(formatted) == [Self.half, Self.half])
    }

    @Test("pickup right, short final bar left")
    func pickupAndShortFinalBar() throws {
        let ts = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
        // A 5/8 pickup holding one note: right-aligned it starts at 3/8 of the bar, so it is an eighth tied to a
        // half; left-aligned it would have been a half tied to an eighth.
        let pickup = Measure(
            voices: [Voice(elements: [ts, Bars.note(5, 8)])],
            actualLength: Fraction(numerator: 5, denominator: 8),
        )
        let full = Self.bar([Bars.note(1, 1)])
        let finalElements: [VoiceElement] = [Bars.note(1, 2), Bars.rest(1, 4)]
        let final = Measure(
            voices: [Voice(elements: finalElements)], actualLength: Fraction(numerator: 3, denominator: 4),
        )
        var score = Self.score([[pickup, full, final]])
        let before = score
        _ = try FormatRhythms(scope: .score, policy: Self.policy).apply(to: &score)
        #expect(Self.durations(score, measure: 0) == [Bars.duration(1, 8), Bars.duration(1, 2)])
        #expect(Self.durations(score, measure: 1) == Self.durations(before, measure: 1))
        // The half note starts the short bar, so it stays a half (right-aligned it would have been split).
        #expect(Self.durations(score, measure: 2) == Self.durations(before, measure: 2))
    }

    @Test("6/8 reduced to 3/4 still spells compound")
    func compoundMeter() throws {
        let ts = VoiceElement.timeSignature(TimeSignature(numerator: 6, denominator: 8))
        // The second eighth-pair of the bar is a quarter starting at 1/4: in 6/8 that is two tied eighths.
        var score = Self.score([[Self.bar([
            ts, Bars.note(1, 8), Bars.note(1, 8), Bars.note(1, 4, pitch: 62), Bars.note(1, 4, pitch: 64),
        ])]])
        _ = try FormatRhythms(scope: .score, policy: Self.policy).apply(to: &score)
        let eighth = Bars.duration(1, 8)
        #expect(Self.durations(score).prefix(4) == [eighth, eighth, eighth, eighth])
        guard case let .chord(first)? = score[Self.slot(element: 3)],
              case let .chord(second)? = score[Self.slot(element: 4)]
        else {
            Issue.record("expected two tied eighths at elements 3 and 4")
            return
        }
        #expect(first.notes[0].tieForward == 1)
        #expect(second.notes[0].tieBack == 1)
    }

    @Test("undo restores the score exactly, EIDs included")
    func undoIsExact() throws {
        var score = Self.score([[Self.bar(Self.tiedPair())]])
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        let before = score
        let inverse = try FormatRhythms(scope: .score, policy: Self.policy).apply(to: &score, ids: &ids)
        #expect(score != before)
        #expect(score.stableFingerprint != before.stableFingerprint)
        _ = try inverse.apply(to: &score, ids: &ids)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
    }

    @Test("session: one undo step, nothingToApply when already formatted, location is the first rewritten element")
    func sessionBehavior() {
        let session = ScoreEditSession(score: Self.score([[Self.bar(Self.tiedPair()), Self.bar(Self.tiedPair())]]))
        let before = session.score
        #expect(session.apply(.formatRhythms(scope: .score, policy: Self.policy)))
        #expect(session.lastAffectedLocation == Self.slot(element: 0))
        let applied = session.score
        #expect(applied != before)
        #expect(Self.durations(applied, measure: 1) == [Self.half, Self.half])

        #expect(!session.apply(.formatRhythms(scope: .score, policy: Self.policy)))
        #expect(session.lastRefusal?.reason == .nothingToApply)

        #expect(session.undo())
        #expect(session.score == before)
        #expect(session.redo())
        #expect(session.score == applied)
    }

    @Test("empty range is refused targetNotFound")
    func emptyRange() {
        var score = Self.score([[Self.bar(Self.tiedPair())]])
        let missing = Self.slot(element: 99)
        let range = VoiceElementRange(start: missing, end: missing)
        let reason = Self.reason { try FormatRhythms(scope: .range(range), policy: Self.policy).apply(to: &score) }
        #expect(reason == .targetNotFound(missing))
    }

    @Test("a measure scope off the score is refused")
    func measureOffScore() {
        var score = Self.score([[Self.bar(Self.tiedPair())]])
        let noStaff = StaffAddress(partIndex: 3, staffIndexInPart: 0)
        #expect(Self.reason {
            try FormatRhythms(scope: .measure(staff: noStaff, measureIndex: 0), policy: Self.policy).apply(to: &score)
        } == .staffNotFound(noStaff))
        #expect(Self.reason {
            try FormatRhythms(scope: .measure(staff: Self.staff0, measureIndex: 5), policy: Self.policy)
                .apply(to: &score)
        } == .targetNotFound(Self.slot(measure: 5, element: 0)))
    }

    @Test("a slur ending on the continuation keeps the chain unmerged")
    func slurEndProtectsOnset() throws {
        var head = Bars.chord(1, 4, tieForward: true)
        head.spanners = [Spanner(
            kind: .slur, rawType: "Slur", nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
        )]
        let score = Self.score([[Self.bar([.chord(head), Bars.note(1, 4, tieBack: true), Bars.rest(1, 2)])]])
        #expect(try FormatRhythms(scope: .score, policy: Self.policy).plan(in: score, ids: EIDAllocator()) == nil)
    }
}
