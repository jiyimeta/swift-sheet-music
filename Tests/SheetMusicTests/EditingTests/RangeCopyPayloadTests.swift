@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("RangeCopyPayload")
struct RangeCopyPayloadTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    @Test("a one-bar range becomes a one-bar score carrying that bar's notes")
    func oneBar() throws {
        let source = EditingFixtures.parityFixture()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: source,
        ))
        #expect(payload.division == source.division)
        #expect(payload.parts.count == 1)
        let voice = payload.parts[0].staves[0].measures[0].voices[0]
        let pitches = voice.elements.compactMap { element -> Int? in
            guard case let .chord(chord) = element, let note = chord.notes.first else { return nil }
            return note.pitch
        }
        #expect(pitches == [60, 62])
    }

    @Test("a two-staff range carries both staves")
    func twoStaves() throws {
        let source = EditingFixtures.parityFixture()
        let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(
                start: Self.slot(0, 1),
                end: VoiceElementID(staff: cello, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
            ),
            in: source,
        ))
        #expect(payload.parts.count == 2)
    }

    @Test("the payload survives an encode and parse round trip")
    func roundTrips() throws {
        let source = EditingFixtures.parityFixture()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: source,
        ))
        let data = try MSCXEncoder.encode(payload)
        let parsed = try MSCXParser.parse(data)
        #expect(parsed.parts.count == payload.parts.count)
        let original = payload.parts[0].staves[0].measures[0].voices[0].elements.count
        #expect(parsed.parts[0].staves[0].measures[0].voices[0].elements.count == original)
    }

    @Test("a range that resolves to nothing yields nil")
    func unresolvable() {
        let source = EditingFixtures.parityFixture()
        #expect(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(9, 0)), in: source,
        ) == nil)
    }
}
