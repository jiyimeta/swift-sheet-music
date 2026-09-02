@testable import SheetMusicCore
import Testing

@Suite("Dynamic.defaultVelocity(for:)")
struct DynamicDefaultVelocityTests {
    @Test("MuseScore's dynList velocities, by subtype", arguments: [
        ("ppppp", 5), ("pppp", 10), ("ppp", 16), ("pp", 33), ("p", 49), ("mp", 64),
        ("mf", 80), ("f", 96), ("ff", 112), ("fff", 126), ("ffff", 127), ("fffff", 127),
    ] as [(String, Int)])
    func table(subtype: String, velocity: Int) {
        #expect(Dynamic.defaultVelocity(for: subtype) == velocity)
    }

    @Test("an unknown subtype is mf")
    func unknownIsMezzoForte() {
        #expect(Dynamic.defaultVelocity(for: "sfz") == 80)
        #expect(Dynamic.defaultVelocity(for: "") == 80)
    }
}
