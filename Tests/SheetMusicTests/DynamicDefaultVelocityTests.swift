@testable import SheetMusicCore
import Testing

@Suite("Dynamic.defaultVelocity(for:)")
struct DynamicDefaultVelocityTests {
    /// MuseScore's `Dynamic::DYN_LIST` velocities (`engraving/dom/dynamic.cpp:50-100`): the `<velocity>` a dynamic of
    /// each subtype is stored and saved with. What it plays is `Dynamic.playbackRole`'s business.
    @Test("MuseScore's dynList velocities, by subtype", arguments: [
        ("pppppp", 1), ("ppppp", 5), ("pppp", 10), ("ppp", 16), ("pp", 33), ("p", 49), ("mp", 64),
        ("mf", 80), ("f", 96), ("ff", 112), ("fff", 126), ("ffff", 127), ("fffff", 127), ("ffffff", 127),
        ("fp", 96), ("pf", 49), ("sf", 112), ("sfz", 112), ("sff", 126), ("sffz", 126), ("sfff", 127),
        ("sfffz", 127), ("sfp", 112), ("sfpp", 112), ("rfz", 112), ("rf", 112), ("fz", 112), ("m", 96),
        ("r", 112), ("s", 112), ("z", 80), ("n", 49),
    ] as [(String, Int)])
    func table(subtype: String, velocity: Int) {
        #expect(Dynamic.defaultVelocity(for: subtype) == velocity)
    }

    @Test("other-dynamics and a token MuseScore does not know are mf")
    func unknownIsMezzoForte() {
        #expect(Dynamic.defaultVelocity(for: "other-dynamics") == 80)
        #expect(Dynamic.defaultVelocity(for: "sfzp") == 80)
        #expect(Dynamic.defaultVelocity(for: "") == 80)
    }
}
