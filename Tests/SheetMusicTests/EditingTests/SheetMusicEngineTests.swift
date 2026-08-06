@testable import SheetMusicCore
import Testing

@Suite("SheetMusicEngine")
struct SheetMusicEngineTests {
    @Test("the stamp is stable across reads")
    func stampIsStable() {
        let stamp1 = SheetMusicEngine.versionStamp
        let stamp2 = SheetMusicEngine.versionStamp
        #expect(stamp1 == stamp2)
    }

    @Test("the stamp is non-zero")
    func stampIsNonZero() {
        #expect(SheetMusicEngine.versionStamp != 0)
    }

    @Test("the version string matches the released version")
    func versionMatchesRelease() {
        #expect(SheetMusicEngine.version == "1.10.0")
    }
}
