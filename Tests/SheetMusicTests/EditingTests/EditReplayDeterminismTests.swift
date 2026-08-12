import Foundation
@testable import SheetMusicCore
import Testing

@Suite("Edit replay determinism")
struct EditReplayDeterminismTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    @Test("two sessions fed the same steps agree at every step")
    func twoSessionsAgree() {
        let steps = EditReplayScript.standard(staff: Self.staff)
        let a = EditReplayScript.fingerprints(of: steps, startingFrom: EditingFixtures.replayFixture())
        let b = EditReplayScript.fingerprints(of: steps, startingFrom: EditingFixtures.replayFixture())
        #expect(a == b)
        #expect(a.count == steps.count + 1)
    }

    @Test("the script actually edits something")
    func scriptIsNotInert() {
        let prints = EditReplayScript.fingerprints(
            of: EditReplayScript.standard(staff: Self.staff), startingFrom: EditingFixtures.replayFixture(),
        )
        #expect(prints.last != prints.first)
        // A script every step of which got refused would produce a flat, single-valued fingerprint sequence and
        // "prove" determinism trivially — this rules that out by requiring real spread across the run.
        #expect(Set(prints).count >= 10)
    }
}
