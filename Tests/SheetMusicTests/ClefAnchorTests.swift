@testable import SheetMusicCore
import Testing

@Suite("ClefAnchor")
struct ClefAnchorTests {
    @Test("explicit and staffDefault are distinct under Hashable")
    func explicitAndStaffDefaultDiffer() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let veID = VoiceElementID(
            staff: staff, measureIndex: 0,
            voiceIndex: 0, elementIndex: 0,
        )
        let a: ClefAnchor = .explicit(veID)
        let b: ClefAnchor = .staffDefault(staff)
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("equal staffDefault anchors hash equal")
    func staffDefaultEquality() {
        let staff = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        // swiftlint:disable:next identical_operands
        #expect(ClefAnchor.staffDefault(staff) == ClefAnchor.staffDefault(staff))
    }

    /// Restatements on two systems are two anchors, which is what keeps a click on one from tinting both — and
    /// neither is the staff default the first system's opening clef carries.
    @Test("restatements differ by bar, and from the staff default")
    func restatementsDifferByBar() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let second: ClefAnchor = .restatement(staff: staff, measureIndex: 4)
        let third: ClefAnchor = .restatement(staff: staff, measureIndex: 9)
        #expect(second != third)
        #expect(second != .staffDefault(staff))
        #expect(second != .restatement(staff: StaffAddress(partIndex: 1, staffIndexInPart: 0), measureIndex: 4))
        #expect(Set([second, third, .staffDefault(staff)]).count == 3)
        // swiftlint:disable:next identical_operands
        #expect(ClefAnchor.restatement(staff: staff, measureIndex: 4) == .restatement(staff: staff, measureIndex: 4))
    }
}

@Suite("ScoreItemID.clef")
struct ScoreItemIDClefTests {
    @Test("staffDefault accessors return staff and zero indices")
    func staffDefaultAccessors() {
        let staff = StaffAddress(partIndex: 2, staffIndexInPart: 1)
        let id: ScoreItemID = .clef(.staffDefault(staff))
        #expect(id.staff == staff)
        #expect(id.measureIndex == 0)
        #expect(id.voiceIndex == 0)
        #expect(id.elementIndex == 0)
    }

    /// A restatement is bar-addressed: it answers with the bar it is drawn at the head of, and approximates
    /// voice and element with `0` — the slot `SetClef(before:)` aims at is voice 0's first chord there.
    @Test("restatement accessors return the bar it is drawn in")
    func restatementAccessors() {
        let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let id: ScoreItemID = .clef(.restatement(staff: staff, measureIndex: 6))
        #expect(id.staff == staff)
        #expect(id.measureIndex == 6)
        #expect(id.voiceIndex == 0)
        #expect(id.elementIndex == 0)
    }

    @Test("explicit accessors mirror the underlying VoiceElementID")
    func explicitAccessors() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let veID = VoiceElementID(
            staff: staff, measureIndex: 3,
            voiceIndex: 1, elementIndex: 2,
        )
        let id: ScoreItemID = .clef(.explicit(veID))
        #expect(id.staff == staff)
        #expect(id.measureIndex == 3)
        #expect(id.voiceIndex == 1)
        #expect(id.elementIndex == 2)
    }
}
