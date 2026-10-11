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
            score.parts.updateValue(at: 1) { partValue in
                partValue.staves.updateValue(at: 0) { staffValue in
                    staffValue.measures[offset].measureRepeatCount = offset + 1
                }
            }
        }
        score.parts.updateValue(at: 1) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[1].voices = [Voice(elements: [
                    .measureRepeat(MeasureRepeat(numMeasures: 4, duration: .measure)),
                ])]
            }
        }

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

    /// MuseScore's `makeMeasureRepeatGroup`: the sign REPLACES what the bar held. Bar 0 of the flute is
    /// `[ts, C4 q, D4 q, r, r]`; its notes and rests become the sign, and the time signature stays in front of it.
    @Test("a bar with notes is replaced by the sign, and undo brings the notes back")
    func replacesNotes() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 0), staff: Self.flute, numMeasures: 1)
        let inverse = try command.apply(to: &score)
        let bar = score.parts[0].staves[0].measures[0]
        #expect(bar.measureRepeatCount == 1)
        #expect(bar.voices.count == 1)
        #expect(bar.voices[0].elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure)),
        ])
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    /// The bar a whole-bar delete used to leave behind — four quarter rests over a second voice's measure rest — is
    /// one a measure repeat can be written into: the second voice goes with the music it held.
    @Test("a bar of two voices becomes one voice holding the sign")
    func replacesASecondVoice() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 1), staff: Self.flute, numMeasures: 1)
        let inverse = try command.apply(to: &score)
        let bar = score.parts[0].staves[0].measures[1]
        #expect(bar.voices.count == 1)
        #expect(bar.voices[0].elements == [.measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure))])
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    /// What is not a note or a rest is not the bar's music, and stays — in front of the sign when it stood in
    /// front of the music, behind it when it stood among it — exactly where a whole-bar delete would have kept it.
    @Test("a dynamic in front of the music and one among it both survive the sign")
    func keepsAnnotations() throws {
        var score = EditingFixtures.parityFixture()
        let piano = VoiceElement.dynamic(Dynamic(subtype: "p", velocity: 40))
        let forte = VoiceElement.dynamic(Dynamic(subtype: "f", velocity: 96))
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0].elements.insert(piano, at: 1, id: EID(first: 77, second: 1))
                staff.measures[0].voices[0].elements.insert(forte, at: 3, id: EID(first: 77, second: 2))
            }
        } // [ts, p, C4 q, f, D4 q, r, r]
        _ = try SetMeasureRepeat(at: MeasureRef(measureIndex: 0), staff: Self.flute, numMeasures: 1).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[0].voices[0].elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)), piano,
            .measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure)), forte,
        ])
    }

    /// A measure repeat is one voice. An upper voice that holds something other than notes and rests cannot go
    /// with the music, so the bar is refused rather than losing it.
    @Test("an upper voice holding an annotation is refused")
    func refusesAnAnnotatedUpperVoice() throws {
        var score = EditingFixtures.parityFixture()
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[1].voices[1] = Voice(elements: [
                    .dynamic(Dynamic(subtype: "p", velocity: 40)), .rest(duration: .measure),
                ])
            }
        }
        let before = score
        let annotated = #expect(throws: SheetMusicError.self) {
            let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 1), staff: Self.flute, numMeasures: 1)
            _ = try command.apply(to: &score)
        }
        #expect(Self.reason(of: annotated) == .measureRepeatSpanNotEmpty(measureIndex: 1))
        #expect(score == before)
    }

    @Test("a bar already in a group, or a bad span, is refused")
    func refusals() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetMeasureRepeat(at: MeasureRef(measureIndex: 1), staff: Self.cello, numMeasures: 2).apply(to: &score)
        let inGroup = #expect(throws: SheetMusicError.self) {
            let command = SetMeasureRepeat(at: MeasureRef(measureIndex: 2), staff: Self.cello, numMeasures: 1)
            _ = try command.apply(to: &score)
        }
        #expect(Self.reason(of: inGroup) == .measureRepeatSpanNotEmpty(measureIndex: 2))
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
        score.parts.updateValue(at: 1) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[2].voices = []
            }
        }
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
