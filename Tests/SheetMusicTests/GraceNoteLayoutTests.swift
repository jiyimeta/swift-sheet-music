@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutElement.graceChord")
struct GraceLayoutElementTests {
    @Test("Case stores hasSlash, mag, relativeX")
    func storesFields() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.graceChord(
            notes: [],
            duration: .eighth,
            stem: .up,
            stemOrigin: .zero,
            relativeX: -10,
            hasSlash: true,
            mag: 0.6,
            voiceIndex: 0
        )
        guard case let .graceChord(_, _, _, _, relX, slash, mag, _) = element else {
            Issue.record("not graceChord"); return
        }
        #expect(relX == -10)
        #expect(slash == true)
        #expect(mag == 0.6)
    }
}
