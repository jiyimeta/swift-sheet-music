import Foundation
@testable import SheetMusicCore
import Testing

@Suite("ElementNavigator")
struct ElementNavigatorTests {
    @Test func `finds the next rest in the same measure`() {
        let score = EditingFixtures.fourQuarterRests()
        let after = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

        let next = ElementNavigator.nextTimedElement(after: after, in: score)

        #expect(next == VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2))
    }

    @Test func `nil after the last element of a single-measure staff`() {
        let score = EditingFixtures.fourQuarterRests()
        let after = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)

        let next = ElementNavigator.nextTimedElement(after: after, in: score)

        #expect(next == nil)
    }

    @Test func `continues into the next measure's same voice`() {
        var score = EditingFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures.append(
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        )
        let after = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)

        let next = ElementNavigator.nextTimedElement(after: after, in: score)

        #expect(next == VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0))
    }

    // MARK: Walking backwards (pad ← key)

    @Test func `finds the previous rest in the same measure`() {
        let score = EditingFixtures.fourQuarterRests()
        let before = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2)

        let previous = ElementNavigator.previousTimedElement(before: before, in: score)

        #expect(
            previous == VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
        )
    }

    @Test func `nil before the first timed element of the staff`() {
        let score = EditingFixtures.fourQuarterRests()
        let before = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

        let previous = ElementNavigator.previousTimedElement(before: before, in: score)

        #expect(previous == nil)
    }

    @Test func `continues back into the previous measure's same voice`() {
        var score = EditingFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures.append(
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        )
        let before = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0)

        let previous = ElementNavigator.previousTimedElement(before: before, in: score)

        #expect(
            previous == VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4),
        )
    }

    @Test func `skips non-timed elements when walking backwards`() {
        var score = EditingFixtures.fourQuarterRests()
        let secondMeasure = Measure(voices: [
            Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .rest(duration: .quarter),
            ]),
        ])
        score.parts[0].staves[0].measures.append(secondMeasure)
        let before = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 1)

        let previous = ElementNavigator.previousTimedElement(before: before, in: score)

        // The clef at index 0 isn't a slot, so the walk carries on into the previous measure's last rest.
        #expect(
            previous == VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4),
        )
    }

    /// Walking forward and back must land where you started — the pad's ← and → keys are each other's inverse.
    @Test func `next and previous are inverses`() {
        var score = EditingFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures.append(
            Measure(voices: [Voice(elements: [.rest(duration: .quarter), .rest(duration: .quarter)])]),
        )
        let start = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2)

        let next = try? #require(ElementNavigator.nextTimedElement(after: start, in: score))
        let back = next.flatMap { ElementNavigator.previousTimedElement(before: $0, in: score) }

        #expect(back == start)
    }

    @Test func `skips non-timed elements at the start of the next measure`() {
        var score = EditingFixtures.fourQuarterRests()
        let secondMeasure = Measure(voices: [
            Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .rest(duration: .quarter),
            ]),
        ])
        score.parts[0].staves[0].measures.append(secondMeasure)
        let after = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)

        let next = ElementNavigator.nextTimedElement(after: after, in: score)

        #expect(next == VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 1))
    }
}
