#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("TextRoleStyle")
struct TextRoleStyleTests {
    @Test func tempoSizeScalesWithSpatium() {
        // Tempo default = 12 pt at reference sp = 5 pt.
        // At sp = 7 pt, expected = 12 * 7 / 5 = 16.8.
        let size = TextRoleStyle.fontSize(for: .tempo, sp: 7)
        #expect(Double(size) == 16.8)
    }

    @Test func lyricsOddSizeScalesWithSpatium() {
        // Lyrics default = 10 pt.
        let size = TextRoleStyle.fontSize(for: .lyricsOdd, sp: 5)
        #expect(Double(size) == 10)
    }

    @Test func titleIgnoresSpatium() {
        // Title is not spatium-dependent — stays at 22 pt.
        let size = TextRoleStyle.fontSize(for: .title, sp: 7)
        #expect(Double(size) == 22)
    }

    @Test func textMarkKindMapsToRole() {
        #expect(TextRoleStyle.style(for: .dynamic) == .dynamics)
        #expect(TextRoleStyle.style(for: .tempo) == .tempo)
        #expect(TextRoleStyle.style(for: .lyrics(color: nil)) == .lyricsOdd)
    }
}
