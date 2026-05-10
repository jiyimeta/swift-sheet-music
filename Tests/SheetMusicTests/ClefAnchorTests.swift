@testable import SheetMusicCore
import Testing

@Suite("ClefAnchor")
struct ClefAnchorTests {
    @Test("explicit and staffDefault are distinct under Hashable")
    func explicitAndStaffDefaultDiffer() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let veID = VoiceElementID(
            staff: staff, measureIndex: 0,
            voiceIndex: 0, elementIndex: 0
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
        #expect(ClefAnchor.staffDefault(staff)
            == ClefAnchor.staffDefault(staff))
    }
}
