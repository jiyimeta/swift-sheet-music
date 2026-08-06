import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("Edit replay determinism")
struct EditReplayDeterminismTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// The fixture both this suite and the device-side replay (SP0 Task 10) start from.
    private static func fixtureScore() throws -> Score {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        return try MSCXParser.parse(contentsOf: url)
    }

    @Test("two sessions fed the same steps agree at every step")
    func twoSessionsAgree() throws {
        let score = try Self.fixtureScore()
        let steps = EditReplayScript.standard(staff: Self.staff)
        let a = EditReplayScript.fingerprints(of: steps, startingFrom: score)
        let b = try EditReplayScript.fingerprints(of: steps, startingFrom: Self.fixtureScore())
        #expect(a == b)
        #expect(a.count == steps.count + 1)
    }

    @Test("the script actually edits something")
    func scriptIsNotInert() throws {
        let score = try Self.fixtureScore()
        let prints = EditReplayScript.fingerprints(
            of: EditReplayScript.standard(staff: Self.staff), startingFrom: score,
        )
        #expect(prints.last != prints.first)
        #expect(Set(prints).count >= 10)
    }
}
