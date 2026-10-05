import Foundation
@testable import SheetMusicBridgeCore
@testable import SheetMusicPDFWriter
import Testing

/// The fonts the Windows renderer bundles, read where they live in this repository.
enum BundledFonts {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SheetMusicRenderWindows/Resources")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func font(_ name: String) throws -> OpenTypeFont {
        try OpenTypeFont(data(name))
    }
}

/// `OpenTypeFont`: what a PDF needs of the bundled fonts — glyph ids through the cmap, and advances that agree with
/// the metrics table the layout measured them by.
struct OpenTypeFontTests {
    @Test func `the treble clef and a letter map to glyphs, an unmapped scalar to notdef`() throws {
        let bravura = try BundledFonts.font("Bravura.otf")
        let edwin = try BundledFonts.font("Edwin-Roman.otf")

        #expect(bravura.glyph(for: 0xE050) != 0)
        #expect(edwin.glyph(for: 0x41) != 0)
        #expect(edwin.glyph(for: 0xE050) == 0)
        #expect(bravura.hasCFFOutlines)
        #expect(bravura.unitsPerEm > 0)
    }

    /// The cmap and `hmtx` read right across a whole repertoire: every advance the metrics table measured for these
    /// faces is the font's own, to a thousandth of an em. Two kinds of character are measured differently on purpose
    /// and left out: a combining mark, which the font gives no advance and CoreText measured standing alone, and the
    /// soft hyphen, which CoreText does not draw. (Edwin-Bold is not compared: the table's `edwin-bold` record was
    /// measured as CoreText's synthesized bold of Edwin, not from Edwin-Bold.otf, so its advances are not that font's.)
    @Test(arguments: [("Bravura.otf", "bravura"), ("Edwin-Roman.otf", "edwin")])
    func `every advance the table carries is the font's own`(file: String, face: String) throws {
        let font = try BundledFonts.font(file)
        let table = try FontMetricsTable.decode(BundledFonts.data("sheet-music.smft"))
        let measured = try #require(table.faces[face])
        var compared = 0
        for (codepoint, entry) in measured.entries {
            let glyph = font.glyph(for: codepoint)
            guard glyph != 0, font.advance(of: glyph) != 0, codepoint != 0xAD else { continue }
            let tableThousandths = entry.advance / table.referenceSize * 1000
            let fontThousandths = font.width(of: glyph)
            #expect(
                abs(Double(fontThousandths) - tableThousandths) <= 1,
                "U+\(String(codepoint, radix: 16)) in \(file): font \(fontThousandths), table \(tableThousandths)",
            )
            compared += 1
        }
        #expect(compared > 10)
    }

    @Test func `a file that is not a font throws instead of trapping`() {
        #expect(throws: OpenTypeFont.Malformed.self) { try OpenTypeFont(Data("not a font".utf8)) }
        #expect(throws: OpenTypeFont.Malformed.self) { try OpenTypeFont(Data([0x4F, 0x54, 0x54, 0x4F, 0, 9])) }
    }

    @Test func `a font cut short throws`() throws {
        let edwin = try BundledFonts.data("Edwin-Roman.otf")

        #expect(throws: OpenTypeFont.Malformed.self) { try OpenTypeFont(edwin.prefix(400)) }
    }
}
