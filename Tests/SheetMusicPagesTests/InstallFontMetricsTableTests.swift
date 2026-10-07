import Foundation
import SheetMusicLayout
@testable import SheetMusicPages
import Testing

/// The provider `installFontMetricsTable(_:)` installs for a host without CoreText — Android's PDF export is the first
/// outside Windows. Checked as the provider it makes (`fontMetricsTableProvider`), never by installing it: every suite
/// in this test process shares `FontMetrics.provider`, and a test that swapped it and put the old value back raced
/// another suite's install and left the stub in place for the rest of the run (CI on 2026-10-07: `LayoutEngine`'s
/// "still StubFontMetricsProvider" assertion stopped the Apple job). The one-line install itself is exercised by its
/// host: folino's print tests lay out through it with nothing else installed.
struct InstallFontMetricsTableTests {
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

    @Test("the shipped table makes a provider that measures from it")
    func makesTheTableProvider() throws {
        let provider = try fontMetricsTableProvider(Self.tableBytes())

        #expect(!(provider is StubFontMetricsProvider))
        // A real box, not the stub's estimate.
        let box = try #require(provider.glyphPathBoundingBox(font: Self.bravuraEm, codepoint: Self.gClef))
        #expect(box.width > 0 && box.height > 0)
        #expect(box != StubFontMetricsProvider().glyphPathBoundingBox(font: Self.bravuraEm, codepoint: Self.gClef))
        // Bravura's ascender is 2012 / 1000 em, so 8.048 at the pointSize-4 "Bravura em" (`FontMetricsInstallTests`).
        #expect(abs(Double(provider.ascent(font: Self.bravuraEm)) - 8.048) < 1e-3)
    }

    @Test("bytes that do not decode throw, before anything is installed")
    func badBytesThrow() {
        #expect(throws: (any Error).self) { try fontMetricsTableProvider(Data()) }
        #expect(throws: (any Error).self) { try fontMetricsTableProvider(Data("not a table".utf8)) }
    }
}
