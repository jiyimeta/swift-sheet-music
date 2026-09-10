@testable import SheetMusicCore
import Testing

enum ElementHitCommandChecks {
    static func remove(_ id: ScoreElementID, from score: inout Score) throws -> any EditCommand {
        let command = try #require(id.removalCommand)
        return try command.apply(to: &score)
    }

    static func apply(_ id: ScoreElementID, fixture: Score? = nil) throws {
        var score = ScoreEditor(score: fixture ?? EditingFixtures.twoConsecutiveC4Chords()).score
        let command: any EditCommand
        switch id {
        case .tie, .slur, .jump, .marker:
            // New-kind checks supply a real score whose storage matches the hit identity.
            score = try ScoreEditor(score: #require(fixture)).score
            command = try #require(id.removalCommand)
        case let .dynamic(anchor):
            command = SetDynamic(at: anchor, subtype: "ff")
        case let .fermata(anchor):
            command = SetFermata(at: anchor, subtype: "fermataLongAbove", timeStretch: 2)
        case let .breath(anchor):
            command = SetBreath(after: anchor, kind: .caesura(.normal), pause: 0)
        case let .tempo(anchor):
            command = SetTempo(anchor: anchor, marking: .init(beatsPerSecond: 3))
        case let .articulation(anchor, kind):
            command = SetArticulation(at: anchor, kind: kind, anchor: nil, present: true)
        case let .spanner(anchor, kind):
            // The source slot is 1; a chord at slot 0 proves this is not an inferred head-of-voice address.
            score.parts[0].staves[0].measures[0].voices[0].elements = [
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .spanner(Spanner(
                    kind: kind,
                    rawType: "",
                    nextMeasuresOffset: 0,
                    nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
                )),
                .chord(Chord(duration: .half, notes: [Note(pitch: 62, tpc: 16)])),
            ]
            command = RemoveSpanner(at: anchor, kind: kind)
        case let .keySignature(measureIndex):
            command = SetKeySignature(measureIndex: measureIndex, concertKey: 3)
        case let .timeSignature(measureIndex):
            command = SetTimeSignature(measureIndex: measureIndex, numerator: 3, denominator: 4)
        case let .barLine(measureIndex, role):
            let measure = MeasureRef(measureIndex: measureIndex)
            if role == .startRepeat {
                command = SetRepeatBarLines(at: measure, startRepeat: true, endRepeatCount: nil)
            } else {
                command = SetBarLine(at: measure, style: .double)
            }
        }
        let item = ScoreItemID.element(id)
        let expected = id.anchor ?? VoiceElementID(
            staff: item.staff, measureIndex: item.measureIndex, voiceIndex: 0, elementIndex: 0,
        )
        #expect(command.affectedLocation == expected)
        let before = score.stableFingerprint
        let inverse = try command.apply(to: &score)
        #expect(score.stableFingerprint != before)
        _ = try inverse.apply(to: &score)
        #expect(score.stableFingerprint == before)
    }
}
