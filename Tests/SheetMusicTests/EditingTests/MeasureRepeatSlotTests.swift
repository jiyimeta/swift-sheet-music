@testable import SheetMusicCore
import Testing

/// A measure repeat is a slot, as MuseScore's `MeasureRepeat` is a `Rest` of the bar's length: it advances the
/// voice's cursor by the bar, a range takes it in, the voice-order walk stops on it, and deleting it — on its own or
/// inside a range — dissolves its group back into measure rests (`Score::deleteItem`).
@Suite("Measure repeat as a slot")
struct MeasureRepeatSlotTests {
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: cello, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func bar(_ score: Score, _ measure: Int) -> Measure {
        score.parts[1].staves[0].measures[measure]
    }

    /// `parityFixture()` with a one-bar repeat on the cello's bar 1, which then holds the sign alone.
    private static func signed(numMeasures: Int = 1) throws -> Score {
        var score = EditingFixtures.parityFixture()
        _ = try SetMeasureRepeat(at: MeasureRef(measureIndex: 1), staff: cello, numMeasures: numMeasures)
            .apply(to: &score)
        return score
    }

    private static func signIndex(_ score: Score, _ measure: Int) -> Int? {
        bar(score, measure).voices[0].elements.values.firstIndex {
            if case .measureRepeat = $0 { true } else { false }
        }
    }

    @Test("the sign advances the cursor by the bar it stands for")
    func signAdvancesByTheBar() throws {
        let score = try Self.signed()
        let sign = try #require(Self.signIndex(score, 1))
        let end = try #require(score.end(of: Self.slot(1, sign)))
        let measureTicks = score.effectiveMeasureDuration(at: Self.cello, measureIndex: 1)
            .ticks(division: score.division)
        #expect(end.tick == (score.onset(of: Self.slot(1, sign))?.tick ?? -1) + measureTicks)
    }

    @Test("a range across the sign's bar takes the sign in")
    func rangeTakesTheSignIn() throws {
        let score = try Self.signed()
        let sign = try Self.slot(1, #require(Self.signIndex(score, 1)))
        // The range's ends are the slots either side of the sign's bar, so the sign itself is only in it by span.
        let before = try #require(ElementNavigator.previousTimedElement(before: sign, in: score))
        let after = try #require(ElementNavigator.nextTimedElement(after: sign, in: score))
        let covered = score.voiceElements(in: VoiceElementRange(start: before, end: after))
        #expect(covered.contains(sign))
    }

    @Test("the voice-order walk stops on the sign, forward and back")
    func walkStopsOnTheSign() throws {
        let score = try Self.signed()
        let sign = try Self.slot(1, #require(Self.signIndex(score, 1)))
        let lastOfBar0 = try #require(ElementNavigator.previousTimedElement(before: sign, in: score))
        #expect(lastOfBar0.measureIndex == 0)
        #expect(ElementNavigator.nextTimedElement(after: lastOfBar0, in: score) == sign)
        let firstOfBar2 = try #require(ElementNavigator.nextTimedElement(after: sign, in: score))
        #expect(firstOfBar2.measureIndex == 2)
        #expect(ElementNavigator.previousTimedElement(before: firstOfBar2, in: score) == sign)
    }

    @Test("the walk passes the rest a later bar of a group holds under the sign")
    func walkSkipsTheContinuationRest() throws {
        let score = try Self.signed(numMeasures: 2)
        let sign = try Self.slot(1, #require(Self.signIndex(score, 1)))
        let next = try #require(ElementNavigator.nextTimedElement(after: sign, in: score))
        #expect(next.measureIndex == 3)
        #expect(ElementNavigator.previousTimedElement(before: next, in: score) == sign)
    }

    /// MuseScore anchors a 2-bar group's sign in its second bar, leaving a rest under it in the first.
    @Test("the walk passes bar 1's rest when the sign stands in bar 2, as MuseScore writes a 2-bar group")
    func walkSkipsTheRestAheadOfAMuseScoreSign() throws {
        var score = try Self.signed(numMeasures: 2)
        let signIndex = try #require(Self.signIndex(score, 1))
        let continuation = Self.bar(score, 2).voices[0].elements.values
        let restIndex = try #require(continuation.firstIndex { $0.isRest })
        let sign = Self.bar(score, 1).voices[0].elements.values[signIndex]
        score.parts.updateValue(at: 1) { part in
            part.staves.updateValue(at: 0) { staff in
                var first = staff.measures[1].voices[0].elements.values
                var second = staff.measures[2].voices[0].elements.values
                first[signIndex] = .rest(duration: .measure)
                second[restIndex] = sign
                staff.measures[1].voices[0] = Voice(elements: first)
                staff.measures[2].voices[0] = Voice(elements: second)
            }
        }
        let lastOfBar0 = try #require(ElementNavigator.previousTimedElement(before: Self.slot(1, signIndex), in: score))
        #expect(lastOfBar0.measureIndex == 0)
        #expect(ElementNavigator.nextTimedElement(after: lastOfBar0, in: score) == Self.slot(2, restIndex))
        #expect(ElementNavigator.previousTimedElement(before: Self.slot(2, restIndex), in: score) == lastOfBar0)
    }

    @Test("deleting the sign dissolves its group into measure rests")
    func deletingTheSignDissolves() throws {
        let score = try Self.signed()
        let session = ScoreEditSession(score: score)
        #expect(try session.apply(.delete(at: Self.slot(1, #require(Self.signIndex(score, 1))))))
        #expect(Self.bar(session.score, 1).measureRepeatCount == nil)
        #expect(Self.signIndex(session.score, 1) == nil)
        #expect(Self.bar(session.score, 1).voices[0].elements.values.contains(.rest(duration: .measure)))
    }

    @Test("deleting a two-bar group's sign dissolves both bars")
    func deletingTwoBarSignDissolvesBoth() throws {
        let score = try Self.signed(numMeasures: 2)
        let session = ScoreEditSession(score: score)
        #expect(try session.apply(.delete(at: Self.slot(1, #require(Self.signIndex(score, 1))))))
        #expect(Self.bar(session.score, 1).measureRepeatCount == nil)
        #expect(Self.bar(session.score, 2).measureRepeatCount == nil)
    }

    /// The shape found in a user's file: the sign with a whole-bar rest behind it in the same voice. Deleting the sign
    /// dissolves the group, and the dissolve folds every timed element of the bar into one measure rest.
    @Test("deleting a sign that has a rest beside it leaves one measure rest")
    func deletingSignWithStrayRestCleansTheBar() throws {
        var score = try Self.signed()
        score.parts.updateValue(at: 1) { part in
            part.staves.updateValue(at: 0) { staff in
                let elements = staff.measures[1].voices[0].elements.values + [.rest(duration: .whole)]
                staff.measures[1].voices[0] = Voice(elements: elements)
            }
        }
        let session = ScoreEditSession(score: score)
        #expect(try session.apply(.delete(at: Self.slot(1, #require(Self.signIndex(score, 1))))))
        let rests = Self.bar(session.score, 1).voices[0].elements.values.filter(\.isRangeSlot)
        #expect(rests == [.rest(duration: .measure)])
    }

    @Test("a range delete covering the sign dissolves its group")
    func rangeDeleteDissolves() throws {
        let score = try Self.signed()
        let sign = try Self.slot(1, #require(Self.signIndex(score, 1)))
        let session = ScoreEditSession(score: score)
        #expect(session.apply(.deleteRange(over: VoiceElementRange(start: sign, end: sign))))
        #expect(Self.bar(session.score, 1).measureRepeatCount == nil)
        #expect(Self.signIndex(session.score, 1) == nil)
    }
}
