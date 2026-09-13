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

    /// A quarter chord, spelled the way `RangeCopyPayloadTests.threeBarsOfQuarters()` spells it.
    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    @Test("a copy that starts mid-bar and crosses a barline pastes whole, appending nothing")
    func pastesAMidBarCrossBarlineCopy() throws {
        // Beat 3 of bar 0 through beat 2 of bar 1 — four contiguous quarters, 64 65 67 69 — landed on bar 2
        // beat 1, where they fill the bar exactly. The only paste test whose SOURCE is neither bar-aligned nor
        // confined to one measure.
        var score = RangeCopyPayloadTests.threeBarsOfQuarters()
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 3), end: Self.slot(1, 1)), in: score,
        )
        _ = try Self.paste(text, at: Self.slot(2, 0)).apply(to: &score)

        #expect(try Self.voice(score, 2).elements == [
            Self.quarter(64, 18), Self.quarter(65, 13), Self.quarter(67, 15), Self.quarter(69, 17),
        ])
        #expect(try #require(score[Self.flute]).measures.count == 3)
        // The bars the copy came from are untouched, so nothing slid while the payload was being carved.
        #expect(try Self.voice(score, 1).elements == [
            Self.quarter(67, 15), Self.quarter(69, 17), Self.quarter(71, 19), Self.quarter(72, 14),
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

    /// A bar's total, walked the way `Score.onset(of:)` walks it. A paste that splits across a barline must
    /// leave every bar it touched exactly as long as it found it.
    private static func ticks(_ voice: Voice) -> Int {
        voice.elements.reduce(0) {
            $0 + $1.cursorAdvance(division: 480, in: Fraction(numerator: 4, denominator: 4))
        }
    }

    @Test("a mid-bar paste splits at the barline, seals the tie it cut, and changes no bar's length")
    func splitsAtTheBarline() throws {
        var score = EditingFixtures.parityFixture()
        // Four quarters — a whole 4/4 bar's worth — landed on beat 3, so half of it belongs to the next bar.
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: score,
        )
        _ = try Self.paste(text, at: Self.slot(1, 2)).apply(to: &score)

        let landed = try Self.voice(score, 1)
        #expect(landed.elements == [
            .rest(duration: .quarter), .rest(duration: .quarter),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
        ])

        // Bar 2 held two tied half notes; the copy's tail covers the first of them exactly, so it is replaced
        // and the survivor's `tieBack` has to have been cleared — that is the seal, and it is a pass a paste
        // landing at tick 0 never reaches.
        let crossed = try Self.voice(score, 2)
        let tieBacks = crossed.elements.compactMap { element -> [Int?]? in
            guard case let .chord(chord) = element, !chord.notes.isEmpty else { return nil }
            return chord.notes.map(\.tieBack)
        }
        #expect(tieBacks == [[nil]])
        #expect(crossed.elements.first == .rest(duration: .quarter))

        #expect(Self.ticks(landed) == 1920)
        #expect(Self.ticks(crossed) == 1920)
    }

    @Test("a paste refused inside the shared rebuild names PasteRange, not DuplicateRange")
    func rebuildRefusalNamesTheCommand() throws {
        var score = EditingFixtures.parityFixture()
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        // A `.locationShift` inside the span the paste will clear: `RangeCopyVoiceRebuild` refuses it, and the
        // refusal is raised in the pass `DuplicateRange` shares.
        var blocked = try Self.voice(score, 1)
        blocked.elements.insert(
            .locationShift(delta: Fraction(numerator: 1, denominator: 8)), at: 2, id: ids.next(),
        )
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[1].voices[0] = blocked
            }
        }
        let before = score
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: score,
        )
        let error = #expect(throws: SheetMusicError.self) {
            _ = try Self.paste(text, at: Self.slot(1, 0)).apply(to: &score)
        }
        guard case let .invalidEdit(refusal)? = error else {
            Issue.record("expected an invalidEdit refusal, got \(String(describing: error))")
            return
        }
        #expect(refusal.operation == "PasteRange")
        #expect(refusal.code == "edit.blockedByUntimedElement")
        #expect(score == before)
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
