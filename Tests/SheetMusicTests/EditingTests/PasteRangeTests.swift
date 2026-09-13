import Foundation
@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("PasteRange")
struct PasteRangeTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func voice(_ score: Score, _ measure: Int, staff: StaffAddress = flute) throws -> Voice {
        try #require(score[staff]).measures[measure].voices[0]
    }

    private static func payloadText(_ range: VoiceElementRange, in score: Score) throws -> String {
        let payload = try #require(RangeCopyPayload.score(for: range, in: score))
        return try #require(String(data: MSCXEncoder.encode(payload), encoding: .utf8))
    }

    /// Every test pastes through the one reader this package ships. `PasteRange` takes it as a parameter because
    /// `SheetMusicCore` cannot import `SheetMusicMSCX` — that module depends on it.
    private static func paste(_ text: String, at location: VoiceElementID) -> PasteRange {
        PasteRange(at: location, payload: text, readPayload: MSCXParser.parse)
    }

    @Test("a copied bar pastes into a later bar")
    func pastesABar() throws {
        var score = EditingFixtures.parityFixture()
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: score,
        )
        _ = try Self.paste(text, at: Self.slot(1, 0)).apply(to: &score)
        let pasted = try Self.voice(score, 1)
        #expect(pasted.elements == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
    }

    @Test("a payload that will not parse is refused and changes nothing")
    func refusesGarbage() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        #expect(throws: SheetMusicError.self) {
            _ = try Self.paste("not a score", at: Self.slot(1, 0)).apply(to: &score)
        }
        #expect(score == before)
    }

    @Test("a payload that will not parse is refused as unreadable, naming no slot of the score")
    func refusesGarbageAsUnreadable() throws {
        var score = EditingFixtures.parityFixture()
        let error = #expect(throws: SheetMusicError.self) {
            _ = try Self.paste("not a score", at: Self.slot(1, 0)).apply(to: &score)
        }
        guard case let .invalidEdit(refusal)? = error else {
            Issue.record("expected an invalidEdit refusal, got \(String(describing: error))")
            return
        }
        #expect(refusal.reason == .unreadablePayload)
        #expect(refusal.operation == "PasteRange")
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: score,
        )
        let inverse = try Self.paste(text, at: Self.slot(1, 0)).apply(to: &score)
        #expect(score != before)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("the payload lands on the staff the location names, not on the staff it was copied from")
    func landsOnTheNamedStaff() throws {
        var score = EditingFixtures.parityFixture()
        let fluteBefore = try Self.voice(score, 1)
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: score,
        )
        let target = VoiceElementID(staff: Self.cello, measureIndex: 1, voiceIndex: 0, elementIndex: 0)
        _ = try Self.paste(text, at: target).apply(to: &score)
        let pasted = try Self.voice(score, 1, staff: Self.cello)
        let fluteAfter = try Self.voice(score, 1)
        #expect(pasted.elements == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        #expect(fluteAfter == fluteBefore)
    }

    @Test("a payload holding no chord or rest is refused as an empty payload")
    func refusesEmptyPayload() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let empty = Score(division: 480, parts: [
            Part(
                id: "1", trackName: "Flute", instrument: Instrument(id: "flute"),
                staves: [Staff(defaultClefType: "G", measures: [Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                ])])])],
            ),
        ])
        let text = try #require(String(data: MSCXEncoder.encode(empty), encoding: .utf8))
        let error = #expect(throws: SheetMusicError.self) {
            _ = try Self.paste(text, at: Self.slot(1, 0)).apply(to: &score)
        }
        guard case let .invalidEdit(refusal)? = error else {
            Issue.record("expected an invalidEdit refusal, got \(String(describing: error))")
            return
        }
        #expect(refusal.reason == .emptyPayload)
        #expect(score == before)
    }
}
