@testable import SheetMusicCore
import Testing

@Suite("VoiceElementRange resolution")
struct VoiceElementRangeTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func id(_ measure: Int, _ element: Int, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    @Test("a range yields chords AND rests whose onset falls inside it, in element order")
    func yieldsChordsAndRests() {
        // measure 0: [keySig, timeSig, r r r r] — elements 2...5; measure 1: [r r r r] — elements 0...3.
        let score = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        let range = VoiceElementRange(start: Self.id(0, 4), end: Self.id(1, 1))
        #expect(score.voiceElements(in: range) == [Self.id(0, 4), Self.id(0, 5), Self.id(1, 0), Self.id(1, 1)])
    }

    @Test("endpoints may be given in either order")
    func endpointsCommute() {
        let score = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        let forward = VoiceElementRange(start: Self.id(0, 4), end: Self.id(1, 1))
        let backward = VoiceElementRange(start: Self.id(1, 1), end: Self.id(0, 4))
        #expect(score.voiceElements(in: forward) == score.voiceElements(in: backward))
    }

    @Test("every voice of a staff in the band is covered")
    func coversAllVoices() {
        var score = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        _ = try? CreateVoice(staff: Self.staff0, measureIndex: 1, voiceIndex: 1).apply(to: &score)
        let range = VoiceElementRange(start: Self.id(1, 0), end: Self.id(1, 3))
        #expect(score.voiceElements(in: range).contains(Self.id(1, 0, voice: 1)))
    }

    @Test("agrees with items(inRangeFrom:to:) on the same endpoints")
    func agreesWithItemRange() {
        var score = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        score[Self.id(0, 3)] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let items = score.items(
            inRangeFrom: .rest(RestID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2)),
            to: .rest(RestID(staff: Self.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0)),
        )
        let fromItems = Set(items.map { VoiceElementID($0) })
        let range = VoiceElementRange(start: Self.id(0, 2), end: Self.id(1, 0))
        #expect(Set(score.voiceElements(in: range)) == fromItems)
    }

    @Test("an unresolvable endpoint yields nothing")
    func unresolvableIsEmpty() {
        let score = EditingFixtures.fourQuarterRests()
        #expect(score.voiceElements(in: VoiceElementRange(start: Self.id(0, 1), end: Self.id(7, 0))).isEmpty)
    }
}
