import Foundation
@testable import SheetMusicCore
import Testing

@Suite("InstrumentChange model")
struct InstrumentChangeModelTests {
    @Test("defaults: visible, no colour, not user-initialized, no instrument")
    func defaults() {
        let change = InstrumentChange(text: "アコーディオン に")
        #expect(change.text == "アコーディオン に")
        #expect(change.instrument == nil)
        #expect(change.isUserInitialized == false)
        #expect(change.visible == true)
        #expect(change.color == nil)
        #expect(change.offsetX == 0)
        #expect(change.offsetY == 0)
    }

    @Test("colour and visible are sugar over elementProperties")
    func sugarWritesThrough() {
        var change = InstrumentChange(text: "to Accordion")
        change.color = ScoreColor(red: 10, green: 20, blue: 30)
        change.visible = false
        #expect(change.elementProperties.color == ScoreColor(red: 10, green: 20, blue: 30))
        #expect(change.elementProperties.visible == false)
    }

    @Test("styleType is the dedicated instrumentChange row")
    func styleType() {
        #expect(InstrumentChange(text: "x").styleType == .instrumentChange)
    }

    @Test("SystemElement carries the change and stays Equatable")
    func systemElementCase() {
        let a = SystemElement.instrumentChange(InstrumentChange(text: "x"))
        let b = SystemElement.instrumentChange(InstrumentChange(text: "x"))
        let c = SystemElement.instrumentChange(InstrumentChange(text: "y"))
        #expect(a == b)
        #expect(a != c)
    }

    /// Two parts, each with two measures; part 0 changes instrument in
    /// measure 1, part 1 does not.
    private func twoPartScore() -> Score {
        let piano = Instrument(id: "piano", channels: [InstrumentChannel(program: 0)])
        let accordion = Instrument(id: "accordion", channels: [InstrumentChannel(program: 21)])
        let flute = Instrument(id: "flute", channels: [InstrumentChannel(program: 73)])
        let bar = Measure(voices: [Voice(elements: [])])
        let staff = Staff(measures: [bar, bar])
        return Score(
            division: 480,
            parts: [
                Part(id: "P1", instrument: piano, staves: [staff]),
                Part(id: "P2", instrument: flute, staves: [staff]),
            ],
            systemMeasures: [
                SystemMeasure(),
                SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: MeasurePosition(
                            offset: Fraction(numerator: 1, denominator: 2),
                        ),
                        element: .instrumentChange(
                            InstrumentChange(text: "to Accordion", instrument: accordion),
                        ),
                        originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    ),
                ]),
            ],
        )
    }

    @Test("timeline is seeded with the part-level instrument at measure 0")
    func timelineSeed() {
        let timeline = twoPartScore().instrumentTimeline(forPart: 1)
        #expect(timeline.count == 1)
        #expect(timeline[0].measureIndex == 0)
        #expect(timeline[0].position == MeasurePosition(offset: Fraction(numerator: 0, denominator: 1)))
        #expect(timeline[0].instrument.id == "flute")
    }

    @Test("a change appends a point at its own measure and position")
    func timelineChange() {
        let timeline = twoPartScore().instrumentTimeline(forPart: 0)
        #expect(timeline.count == 2)
        #expect(timeline[0].instrument.id == "piano")
        #expect(timeline[1].measureIndex == 1)
        #expect(timeline[1].position.offset == Fraction(numerator: 1, denominator: 2))
        #expect(timeline[1].instrument.id == "accordion")
    }

    @Test("a change on part 0 does not leak into part 1")
    func timelineIsPartScoped() {
        let timeline = twoPartScore().instrumentTimeline(forPart: 1)
        #expect(timeline.map(\.instrument.id) == ["flute"])
    }

    @Test("a text-only change contributes no point")
    func textOnlyChangeIsNotATimelinePoint() {
        var score = twoPartScore()
        score.systemMeasures[1].elements = [
            PositionedSystemElement(
                position: MeasurePosition(offset: Fraction(numerator: 0, denominator: 1)),
                element: .instrumentChange(InstrumentChange(text: "no instrument")),
                originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            ),
        ]
        #expect(score.instrumentTimeline(forPart: 0).count == 1)
    }

    @Test("an out-of-range part index yields an empty timeline")
    func outOfRangePart() {
        #expect(twoPartScore().instrumentTimeline(forPart: 9).isEmpty)
    }
}
