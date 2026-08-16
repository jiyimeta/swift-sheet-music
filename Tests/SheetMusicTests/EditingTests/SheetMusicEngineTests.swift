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
        // A hand-edited literal is the only thing enforcing the bump; there is no automated
        // release process that touches it. The in-flight build carried a `-w9` suffix and was
        // published only to a local `~/.m2`, so it stamps differently from this tagged one — see
        // the constant's own doc for why that difference is load-bearing.
        #expect(SheetMusicEngine.version == "1.15.0")
    }

    @Test("the stamp is the FNV-1a of the version string")
    func stampMatchesTheWrittenOutValue() {
        // Written out, not recomputed: a host compares its own compiled-in expectation against
        // this number over JNI, and both sides deriving it from the same expression would make a
        // wrong hash agree with itself. 1.13.1 was 7339729597660573583 and the in-flight
        // 1.15.0-w9 build was 3188487432499784217, so the three are visibly distinct.
        #expect(SheetMusicEngine.versionStamp == 3_598_528_033_961_937_950)
    }
}
