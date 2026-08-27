@testable import SheetMusicCore
import Testing

@Suite("EditRefusal")
struct EditRefusalTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let voiceID = VoiceElementID(
        staff: staff,
        measureIndex: 1,
        voiceIndex: 2,
        elementIndex: 3,
    )
    private static let noteID = NoteID(
        staff: staff,
        measureIndex: 1,
        voiceIndex: 2,
        elementIndex: 3,
        noteIndexInChord: 4,
    )

    @Test("DeleteVoiceElement reports a typed targetNotFound refusal")
    func deleteVoiceElementReportsTargetNotFound() {
        var score = EditingFixtures.fourQuarterRests()
        let outOfRange = VoiceElementID(
            staff: Self.staff,
            measureIndex: 99,
            voiceIndex: 0,
            elementIndex: 0,
        )
        do {
            _ = try DeleteVoiceElement(at: outOfRange).apply(to: &score)
            Issue.record("expected invalidEdit")
        } catch let error as SheetMusicError {
            guard case let .invalidEdit(refusal) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(refusal.reason == .targetNotFound(outOfRange))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("EditRefusal reason codes are stable identifiers and unique")
    func reasonCodesAreIdentifiersAndUnique() {
        let codes = Self.sampleReasons.map {
            EditRefusal(operation: "Test", reason: $0).code
        }
        #expect(Set(codes).count == codes.count)
        for code in codes {
            #expect(code.hasPrefix("edit."))
            #expect(code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." })
        }
    }

    private static var sampleReasons: [EditRefusal.Reason] {
        [
            .targetNotFound(voiceID),
            .noteNotFound(noteID),
            .staffNotFound(staff),
            .wrongElementKind(at: voiceID, expected: .chord),
            .insufficientRoom(neededTicks: 480, availableTicks: 240),
            .blockedByUntimedElement(at: voiceID),
            .insideTuplet(at: voiceID),
            .indivisibleTuplet(targetTicks: 480, actualNotes: 7),
            .invalidTupletRatio(actualNotes: 1, normalNotes: 0),
            .tupletOverlap(rangeStart: 1, rangeEnd: 2, tupletStart: 2, tupletEnd: 4),
            .duplicatePitch(60),
            .emptyPayload,
            .nothingToUndo,
            .nothingToRedo,
            .compositeTooDeep(limit: 8),
            .nothingToApply,
            .cannotDeleteOnlyMeasure,
            .cannotRemoveLastPart,
            .cannotRemoveInitialSignature,
            .unexpected(description: "boom"),
        ]
    }
}
