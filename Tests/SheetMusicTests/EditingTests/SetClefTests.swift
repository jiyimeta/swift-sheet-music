@testable import SheetMusicCore
import Testing

/// `SetClef` and `RemoveClef` — a mid-bar clef inserted before the chord it applies to, replaced in place when
/// the chord already has one, and the header rule at the head of a bar.
@Suite("SetClef")
struct SetClefTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements
    }

    private static func clefType(_ element: VoiceElement) -> String? {
        if case let .clef(clef) = element { clef.concertClefType } else { nil }
    }

    @Test("a mid-bar clef is inserted right before its chord")
    func insertsMidBar() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4, D4, r, r]
        _ = try SetClef(before: Self.slot(0, 2), clef: .alto).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(Self.clefType(elements[2]) == "C3")
        #expect(elements[3] == .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])))
    }

    @Test("a clef before the bar's first chord goes to index 0, ahead of the time signature")
    func headerRule() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetClef(before: Self.slot(0, 1), clef: .bass).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(Self.clefType(elements[0]) == "F")
        #expect(elements[1] == .timeSignature(TimeSignature(numerator: 4, denominator: 4)))
        #expect(MeasureStructure.leadingSignaturePrefix(of: score.parts[0].staves[0].measures[0].voices[0]).count == 2)
    }

    @Test("a clef already before the chord is replaced in place, keeping visibility and dropping a stale type")
    func replacesInPlace() throws {
        var score = EditingFixtures.parityFixture()
        var hidden = Clef(concertClefType: "G", transposingClefType: "G8vb")
        hidden.visible = false
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(.clef(hidden), at: 2)
        // [ts, C4, clef, D4, r, r] — the D4 is element 3 now.
        _ = try SetClef(before: Self.slot(0, 3), clef: .tenor).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        guard case let .clef(clef) = elements[2] else { Issue.record("expected the clef at 2"); return }
        #expect(clef.concertClefType == "C4")
        #expect(clef.transposingClefType == nil)
        #expect(clef.visible == false)
    }

    @Test("the clef lands after a mid-bar key signature and before the chord's dynamic")
    func afterSignaturesBeforeAnnotations() throws {
        var score = EditingFixtures.parityFixture()
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(
            contentsOf: [.keySignature(KeySignature(concertKey: 2)), .dynamic(Dynamic(subtype: "p", velocity: 49))],
            at: 2,
        )
        // [ts, C4, key, dynamic, D4, r, r]
        _ = try SetClef(before: Self.slot(0, 4), clef: .bass).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements[2] == .keySignature(KeySignature(concertKey: 2)))
        #expect(Self.clefType(elements[3]) == "F")
        #expect(elements[4] == .dynamic(Dynamic(subtype: "p", velocity: 49)))
    }

    @Test("undo restores the score exactly, for the insert and for the replace")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try SetClef(before: Self.slot(0, 2), clef: .alto).apply(to: &score)
        let inserted = score
        let replaceInverse = try SetClef(before: Self.slot(0, 3), clef: .bass).apply(to: &score)
        _ = try replaceInverse.apply(to: &score)
        #expect(score == inserted)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("RemoveClef drops the clef and its inverse puts it back")
    func removeAndUndo() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetClef(before: Self.slot(0, 2), clef: .alto).apply(to: &score)
        let withClef = score
        let inverse = try RemoveClef(at: Self.slot(0, 2)).apply(to: &score)
        #expect(score == EditingFixtures.parityFixture())
        _ = try inverse.apply(to: &score)
        #expect(score == withClef)
    }

    @Test("the other staff and the other bars are untouched")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        _ = try SetClef(before: Self.slot(0, 2), clef: .alto).apply(to: &score)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
    }

    @Test("a non-timed target, a non-clef removal and a missing element are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let untimed = #expect(throws: SheetMusicError.self) {
            _ = try SetClef(before: Self.slot(0, 0), clef: .alto).apply(to: &score)
        }
        #expect(Self.reason(of: untimed) == .wrongElementKind(at: Self.slot(0, 0), expected: .timed))
        let notAClef = #expect(throws: SheetMusicError.self) {
            _ = try RemoveClef(at: Self.slot(0, 1)).apply(to: &score)
        }
        #expect(Self.reason(of: notAClef) == .wrongElementKind(at: Self.slot(0, 1), expected: .clef))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetClef(before: Self.slot(0, 9), clef: .alto).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(0, 9)))
        #expect(throws: SheetMusicError.self) {
            _ = try RemoveClef(at: Self.slot(9, 0)).apply(to: &score)
        }
        #expect(score == before)
    }

    @Test("an anchor in voice 1 is refused — a clef belongs to the staff, and layout reads voice 0's")
    func refusesNonZeroVoice() {
        var score = EditingFixtures.parityFixture()
        let before = score
        // Measure 1 of the flute has a second voice whose only element is a measure rest.
        let inVoiceOne = VoiceElementID(staff: Self.flute, measureIndex: 1, voiceIndex: 1, elementIndex: 0)
        let refused = #expect(throws: SheetMusicError.self) {
            _ = try SetClef(before: inVoiceOne, clef: .alto).apply(to: &score)
        }
        #expect(Self.reason(of: refused) == .voiceMismatch(
            from: VoiceRef(inVoiceOne),
            to: VoiceRef(staff: Self.flute, measureIndex: 1, voiceIndex: 0),
        ))
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
