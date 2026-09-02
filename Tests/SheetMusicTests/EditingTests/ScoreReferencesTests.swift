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
}
