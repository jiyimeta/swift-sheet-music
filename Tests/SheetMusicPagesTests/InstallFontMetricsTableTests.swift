import Foundation
import SheetMusicBridgeCore
import SheetMusicLayout
import SheetMusicPages
import Testing

/// `installFontMetricsTable(_:)` is what a host without CoreText calls before laying out a print with `ScorePages` —
/// Android's PDF export is the first outside Windows. It writes the process-wide provider, so each test parks a
/// sentinel there first and restores what was there in `defer`. The sentinel forwards every metric to the provider it
/// replaced: a suite elsewhere that lays out through the global in that instant measures exactly as before, and only
/// its type tells the tests whether the install replaced it.
///
/// Plain `import SheetMusicPages`, no `@testable`: the function is reached the way a host reaches it. (It cannot prove
/// the symbol is `public` — a test target in this package sees `package` symbols too; Folino's call does that.)
@Suite("installFontMetricsTable", .serialized)
struct InstallFontMetricsTableTests {
    private struct Sentinel: FontMetricsProvider {
        let wrapped: any FontMetricsProvider

        func ascent(font: LayoutFont) -> CGFloat {
            wrapped.ascent(font: font)
        }

        func descent(font: LayoutFont) -> CGFloat {
            wrapped.descent(font: font)
        }

        func leading(font: LayoutFont) -> CGFloat {
            wrapped.leading(font: font)
        }

        func renderingTextFont(_ font: LayoutFont) -> LayoutFont {
            wrapped.renderingTextFont(font)
        }

        func glyphPathBoundingBox(font: LayoutFont, codepoint: UInt16) -> CGRect? {
            wrapped.glyphPathBoundingBox(font: font, codepoint: codepoint)
        }

        func typographicWidth(text: String, font: LayoutFont) -> CGFloat {
            wrapped.typographicWidth(text: text, font: font)
        }

        func caretOffsets(text: String, font: LayoutFont) -> [CGFloat] {
            wrapped.caretOffsets(text: text, font: font)
        }

        func selectionOffsets(text: String, font: LayoutFont, range: Range<Int>) -> [ClosedRange<CGFloat>] {
            wrapped.selectionOffsets(text: text, font: font, range: range)
        }

        func characterIndex(forOffset offset: CGFloat, text: String, font: LayoutFont) -> Int {
            wrapped.characterIndex(forOffset: offset, text: text, font: font)
        }

        func inkBounds(text: String, font: LayoutFont) -> InkBounds {
            wrapped.inkBounds(text: text, font: font)
        }

        func textInkBounds(text: String, font: LayoutFont) -> CGRect? {
            wrapped.textInkBounds(text: text, font: font)
        }
    }

    private static func tableBytes() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicPagesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Web/sheet-music-web/assets/sheet-music.smft")
        return try Data(contentsOf: url)
    }

    private static let bravuraEm = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
    private static let gClef: UInt16 = 0xE050

    @Test("installing the shipped table replaces the provider with one that measures from it")
    func installsTheTable() throws {
        let previous = FontMetrics.provider
        defer { FontMetrics.provider = previous }
        FontMetrics.provider = Sentinel(wrapped: previous)

        try installFontMetricsTable(Self.tableBytes())

        let installed = FontMetrics.provider
        #expect(!(installed is Sentinel))
        // The table's own measurement: what a provider made from the same bytes answers, a real box rather than the
        // stub's estimate.
        let table = try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Self.tableBytes()))
        let box = try #require(installed.glyphPathBoundingBox(font: Self.bravuraEm, codepoint: Self.gClef))
        #expect(box == table.glyphPathBoundingBox(font: Self.bravuraEm, codepoint: Self.gClef))
        #expect(box.width > 0 && box.height > 0)
        #expect(box != StubFontMetricsProvider().glyphPathBoundingBox(font: Self.bravuraEm, codepoint: Self.gClef))
        // Bravura's ascender is 2012 / 1000 em, so 8.048 at the pointSize-4 "Bravura em" (`FontMetricsInstallTests`).
        #expect(abs(Double(installed.ascent(font: Self.bravuraEm)) - 8.048) < 1e-3)
    }

    @Test("bytes that do not decode throw and leave the provider as it was")
    func badBytesLeaveTheProvider() {
        let previous = FontMetrics.provider
        defer { FontMetrics.provider = previous }
        FontMetrics.provider = Sentinel(wrapped: previous)

        #expect(throws: (any Error).self) { try installFontMetricsTable(Data()) }

        #expect(FontMetrics.provider is Sentinel)
    }
}
