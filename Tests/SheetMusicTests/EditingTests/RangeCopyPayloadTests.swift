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

    @Test("a range starting on a measure with no time signature of its own inherits the prevailing one")
    func insertsPrevailingTimeSignature() throws {
        // Measure 0 carries the fixture's leading time signature; measure 1 has none of its own — the shape a
        // real second measure has (`EditingFixtures.twoMeasuresOfQuarterRests()`'s own doc comment).
        let source = EditingFixtures.twoMeasuresOfQuarterRests()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 3)), in: source,
        ))
        let elements = payload.parts[0].staves[0].measures[0].voices[0].elements
        let first = try #require(elements.first)
        guard case let .timeSignature(timeSignature) = first else {
            Issue.record("expected the payload's first measure to open with the inherited time signature")
            return
        }
        #expect(timeSignature == TimeSignature(numerator: 4, denominator: 4))
    }

    @Test("a spanner, location shift and measure repeat in a boundary measure are excluded from the payload")
    func excludesUnsafeUntimedKindsAtBoundary() throws {
        var source = EditingFixtures.parityFixture()
        source.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0] = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .locationShift(delta: Fraction(numerator: 0, denominator: 4)),
                    .spanner(Spanner(
                        kind: .hairpin, rawType: "HairPin",
                        hairpin: Spanner.HairpinPayload(subtype: .crescendo),
                    )),
                    .measureRepeat(MeasureRepeat(numMeasures: 1, duration: .quarter)),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
                    .rest(duration: .quarter), .rest(duration: .quarter),
                ])
            }
        }
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 4), end: Self.slot(0, 7)), in: source,
        ))
        let elements = payload.parts[0].staves[0].measures[0].voices[0].elements
        let hasUnsafeKind = elements.contains { element in
            switch element {
            case .locationShift, .measureRepeat, .spanner: true
            default: false
            }
        }
        #expect(!hasUnsafeKind)
        let pitches = elements.compactMap { element -> Int? in
            guard case let .chord(chord) = element, let note = chord.notes.first else { return nil }
            return note.pitch
        }
        #expect(pitches == [60, 62])
    }

    @Test("a range that resolves to nothing yields nil")
    func unresolvable() {
        let source = EditingFixtures.parityFixture()
        #expect(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(9, 0)), in: source,
        ) == nil)
    }
}
