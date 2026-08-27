@testable import SheetMusicLayout
import Testing

struct GlissandoWavyTests {
    // MARK: - wavyGlyphRun geometry

    @Test func centeredGlyphRun() {
        // length=50, advance=12 → count=floor(50/12)=4,
        // startX=(50-48)/2=1.0
        let run = GlissandoGeometry.wavyGlyphRun(length: 50, advance: 12)
        #expect(run.count == 4)
        #expect(abs(run.startX - 1.0) < 0.001)
    }

    @Test func zeroCountWhenTooShort() {
        // length < advance → no copies fit; use destructuring so
        // swiftlint's empty_count rule doesn't fire on a tuple field.
        let (count, _) = GlissandoGeometry.wavyGlyphRun(length: 5, advance: 12)
        #expect(count == 0)
    }

    @Test func zeroAdvanceReturnsZeroCount() {
        let (count, _) = GlissandoGeometry.wavyGlyphRun(length: 50, advance: 0)
        #expect(count == 0)
    }
}
