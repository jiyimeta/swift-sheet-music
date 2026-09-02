@testable import SheetMusicCore
import Testing

@Suite("Score references")
struct ScoreReferencesTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    @Test("the four reference types are plain hashable values")
    func referenceTypesAreValues() {
        let measure = MeasureRef(measureIndex: 2)
        let part = PartRef(partIndex: 1)
        let voice = VoiceRef(staff: Self.staff0, measureIndex: 2, voiceIndex: 1)
        let range = VoiceElementRange(
            start: VoiceElementID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
            end: VoiceElementID(staff: Self.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0),
        )
        #expect(measure == MeasureRef(measureIndex: 2))
        #expect(part.partIndex == 1)
        #expect(voice.voiceIndex == 1)
        #expect(Set([range, range]).count == 1)
    }

    @Test("a MeasureRef is contained iff it indexes the first staff's measures")
    func measureRefContainment() {
        let score = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        #expect(score.contains(MeasureRef(measureIndex: 0)))
        #expect(score.contains(MeasureRef(measureIndex: 1)))
        #expect(!score.contains(MeasureRef(measureIndex: 2)))
        #expect(!score.contains(MeasureRef(measureIndex: -1)))
    }

    @Test("part, voice, measure and system subscripts read and write in place")
    func subscriptsReadAndWrite() {
        var score = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        let voiceRef = VoiceRef(staff: Self.staff0, measureIndex: 1, voiceIndex: 0)
        #expect(score[voice: voiceRef]?.elements.count == 4)
        score[voice: voiceRef] = Voice(elements: [.rest(duration: .measure)])
        #expect(score[voice: voiceRef]?.elements.count == 1)

        let measureRef = MeasureRef(measureIndex: 1)
        var measure = score[measure: measureRef, staff: Self.staff0]
        measure?.lineBreak = true
        score[measure: measureRef, staff: Self.staff0] = measure
        #expect(score.parts[0].staves[0].measures[1].lineBreak)

        #expect(score[system: measureRef] == nil, "an in-memory score has an empty lane")
        score.systemMeasures = [SystemMeasure(), SystemMeasure()]
        score[system: measureRef] = SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: "B"))),
        ])
        #expect(score[system: measureRef]?.elements.count == 1)

        let partRef = PartRef(partIndex: 0)
        var part = score[part: partRef]
        part?.trackName = "Renamed"
        score[part: partRef] = part
        #expect(score.parts[0].trackName == "Renamed")
    }

    @Test("out-of-range reads are nil and out-of-range writes are ignored")
    func outOfRangeIsInert() {
        var score = EditingFixtures.fourQuarterRests()
        let before = score
        #expect(score[part: PartRef(partIndex: 3)] == nil)
        #expect(score[voice: VoiceRef(staff: Self.staff0, measureIndex: 0, voiceIndex: 2)] == nil)
        #expect(score[measure: MeasureRef(measureIndex: 5), staff: Self.staff0] == nil)
        score[voice: VoiceRef(staff: Self.staff0, measureIndex: 0, voiceIndex: 2)] = Voice(elements: [])
        score[measure: MeasureRef(measureIndex: 5), staff: Self.staff0] = Measure(voices: [])
        score[system: MeasureRef(measureIndex: 5)] = SystemMeasure()
        #expect(score == before)
    }
}
