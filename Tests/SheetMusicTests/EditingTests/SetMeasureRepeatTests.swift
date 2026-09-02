@testable import SheetMusicCore
import Testing

@Suite("SetMeasureRepeat")
struct SetMeasureRepeatTests {
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    @Test("a two-bar repeat marks both bars and writes the sign into the first")
    func writesTwoBarRepeat() throws {
        var score = EditingFixtures.parityFixture()
        let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 1), staff: Self.cello, numMeasures: 2)
        _ = try command.apply(to: &score)
        let bars = score.parts[1].staves[0].measures
        #expect(bars[1].measureRepeatCount == 1)
        #expect(bars[2].measureRepeatCount == 2)
        #expect(bars[3].measureRepeatCount == nil)
        guard case let .measureRepeat(sign) = bars[1].voices[0].elements[0] else {
            Issue.record("no sign")
            return
        }
        #expect(sign.numMeasures == 2)
        #expect(bars[2].voices[0].elements == [.rest(duration: .measure)])
        let otherStaff = score.parts[0].staves[0].measures[1].measureRepeatCount
        #expect(otherStaff == nil, "other staff untouched")
    }

    @Test("undo restores the bars byte-exact")
    func undoRestores() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 0), staff: Self.cello, numMeasures: 1)
        let inverse = try command.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("clearing restores measure rests and keeps a leading time signature")
    func clearing() throws {
        var score = EditingFixtures.parityFixture()
        let target = MeasureRef(measureIndex: 0)
        _ = try SetMeasureRepeat(at: target, staff: Self.cello, numMeasures: 1).apply(to: &score)
        _ = try SetMeasureRepeat(at: target, staff: Self.cello, numMeasures: nil).apply(to: &score)
        let m0 = score.parts[1].staves[0].measures[0]
        #expect(m0.measureRepeatCount == nil)
        #expect(m0.voices[0].elements.count == 2)
        guard case .timeSignature = m0.voices[0].elements[0] else {
            Issue.record("prefix lost")
            return
        }
        #expect(m0.voices[0].elements[1] == .rest(duration: .measure))
    }

    @Test("a trailing barline survives the sign, undo, and the clear")
    func keepsTrailingBarLine() throws {
        var score = EditingFixtures.parityFixture()
        let target = MeasureRef(measureIndex: 1)
        _ = try SetBarLine(at: target, style: .double).apply(to: &score)
        let withBarLine = score
        let double = VoiceElement.barLine(BarLine(subtype: "double"))

        let inverse = try SetMeasureRepeat(at: target, staff: Self.cello, numMeasures: 1).apply(to: &score)
        #expect(score.parts[1].staves[0].measures[1].voices[0].elements.count == 2)
        guard case .measureRepeat = score.parts[1].staves[0].measures[1].voices[0].elements[0] else {
            Issue.record("no sign")
            return
        }
        #expect(score.parts[1].staves[0].measures[1].voices[0].elements[1] == double)

        _ = try inverse.apply(to: &score)
        #expect(score == withBarLine, "undo is byte-exact")

        _ = try SetMeasureRepeat(at: target, staff: Self.cello, numMeasures: 1).apply(to: &score)
        _ = try SetMeasureRepeat(at: target, staff: Self.cello, numMeasures: nil).apply(to: &score)
        #expect(score.parts[1].staves[0].measures[1].voices[0].elements == [.rest(duration: .measure), double])
    }

    @Test("a MuseScore group whose sign sits in the second bar still dissolves")
    func clearsGroupWhoseSignSitsInTheSecondBar() throws {
        var score = EditingFixtures.parityFixture()
        // MuseScore anchors a 4-bar group's `%` in bar 2 of the group; bar 1 stays a measure rest.
        for offset in 0 ..< 4 {
            score.parts[1].staves[0].measures[offset].measureRepeatCount = offset + 1
        }
        score.parts[1].staves[0].measures[1].voices = [Voice(elements: [
            .measureRepeat(MeasureRepeat(numMeasures: 4, duration: .measure)),
        ])]

        let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 0), staff: Self.cello, numMeasures: nil)
        _ = try command.apply(to: &score)

        let bars = score.parts[1].staves[0].measures
        #expect(bars.allSatisfy { $0.measureRepeatCount == nil })
        // Bar 0 keeps its leading time signature; the other three are bare measure rests.
        #expect(bars[0].voices[0].elements.count == 2)
        #expect(bars[1].voices[0].elements == [.rest(duration: .measure)])
        #expect(bars[2].voices[0].elements == [.rest(duration: .measure)])
        #expect(bars[3].voices[0].elements == [.rest(duration: .measure)])
    }

    @Test("a bar with notes, a second voice, or a bad span is refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let withNotes = #expect(throws: SheetMusicError.self) {
            let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 0), staff: Self.flute, numMeasures: 1)
            _ = try command.apply(to: &score)
        }
        #expect(Self.reason(of: withNotes) == .measureRepeatSpanNotEmpty(measureIndex: 0))
        let secondVoice = #expect(throws: SheetMusicError.self) {
            let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 1), staff: Self.flute, numMeasures: 1)
            _ = try command.apply(to: &score)
        }
        #expect(Self.reason(of: secondVoice) == .measureRepeatSpanNotEmpty(measureIndex: 1))
        let pastEnd = #expect(throws: SheetMusicError.self) {
            let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 3), staff: Self.cello, numMeasures: 2)
            _ = try command.apply(to: &score)
        }
        #expect(Self.reason(of: pastEnd) == .invalidMeasureRepeatSpan(numMeasures: 2))
        let oddLength = #expect(throws: SheetMusicError.self) {
            let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 1), staff: Self.cello, numMeasures: 3)
            _ = try command.apply(to: &score)
        }
        #expect(Self.reason(of: oddLength) == .invalidMeasureRepeatSpan(numMeasures: 3))
    }

    @Test("clearing a group whose continuation bar has no voice at all is refused, not trapped")
    func refusesVoicelessContinuationBar() throws {
        var score = EditingFixtures.parityFixture()
        let target = MeasureRef(measureIndex: 1)
        _ = try SetMeasureRepeat(at: target, staff: Self.cello, numMeasures: 2).apply(to: &score)
        // A bar with no voices at all is constructible, and the clear path used to index `voices[0]` blind.
        score.parts[1].staves[0].measures[2].voices = []
        let voiceless = #expect(throws: SheetMusicError.self) {
            _ = try SetMeasureRepeat(at: target, staff: Self.cello, numMeasures: nil).apply(to: &score)
        }
        #expect(Self.reason(of: voiceless) == .measureRepeatSpanNotEmpty(measureIndex: 2))
        #expect(score.parts[1].staves[0].measures[1].measureRepeatCount == 1, "refused before mutating")
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
