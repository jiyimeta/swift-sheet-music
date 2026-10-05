import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicLayout
@testable import SheetMusicPDFWriter
@testable import SheetMusicRenderWindows
import Testing

/// What a PDF of a score takes from the Windows text path, checked against what Direct2D draws: Edwin's styled faces
/// measured as drawn, the system face's caret offsets where the drawn layout puts each character, and the system
/// face's file the one DirectWrite draws from.
@Suite("Text faces as drawn")
struct TextFaceTests {
    private static func tableProvider() throws -> any FontMetricsProvider {
        let table = try Data(contentsOf: BundledResources.url(BundledResources.metricsTableFileName))
        return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(table))
    }

    /// The bundled table's bold, italic and bold-italic Edwin advance each character as DirectWrite lays it out in
    /// Edwin's own face of that style — the face `DrawCommandWalker` draws and the PDF embeds — so a bold title is as
    /// wide as the layout measured it. (Each character alone: the table carries no kerning, which a run would add.)
    @Test(
        "the table's styled Edwin advances are DirectWrite's in the face it draws",
        arguments: [(FontWeight.bold, false), (.regular, true), (.bold, true)],
    )
    func styledAdvancesMatchTheDrawnFace(weight: FontWeight, isItalic: Bool) throws {
        let table = try Self.tableProvider()
        let drawn = try DirectWriteTextMeasurer(family: "Edwin", fontFiles: ScoreSurface.bundledFontFiles)
        let font = LayoutFont(face: "Edwin", pointSize: 100, weight: weight, isItalic: isItalic)
        for character in "AWgm1 " {
            let measured = try #require(drawn.measure(String(character), font: font), "\(character)")
            #expect(
                abs(measured.advance - Double(table.typographicWidth(text: String(character), font: font))) < 0.05,
                "\(weight) \(isItalic ? "italic " : "")\(character)",
            )
        }
        // Not vacuous: the styled face's letters are not the regular face's.
        let regular = try #require(drawn.measure("AWgm", font: LayoutFont(face: "Edwin", pointSize: 100)))
        let styled = try #require(drawn.measure("AWgm", font: font))
        #expect(abs(styled.advance - regular.advance) > 0.5)
    }

    @Test("the system face's caret offsets run from zero to its measured width, kerning included")
    func systemCaretsFollowTheDrawnLayout() throws {
        let provider = try WindowsFontMetricsProvider(base: Self.tableProvider())
        let font = LayoutFont(face: "", pointSize: 12, weight: .semibold)
        for text in ["AVATAR", "Violoncello", "12", "Fl."] {
            let offsets = provider.caretOffsets(text: text, font: font).map { Double($0) }
            #expect(offsets.count == text.utf16.count + 1, "\(text)")
            #expect(offsets.first == 0, "\(text)")
            #expect(abs((offsets.last ?? 0) - Double(provider.typographicWidth(text: text, font: font))) < 0.01)
            #expect(offsets == offsets.sorted(), "\(text)")
        }
        // Segoe UI kerns "AV": the V starts before the A's own advance ends, which a sum of lone advances misses.
        let pair = provider.caretOffsets(text: "AV", font: font).map { Double($0) }
        #expect(pair[1] < Double(provider.typographicWidth(text: "A", font: font)) - 0.01)
    }

    @Test("the system face's file is a TrueType font, its own for each weight")
    func systemFileIsTheDrawnFace() throws {
        let text = try WindowsTextFonts(fontFiles: ScoreSurface.bundledFontFiles)
        let regular = try #require(text.systemFace(weight: .regular, isItalic: false))
        let semibold = try #require(text.systemFace(weight: .semibold, isItalic: false))
        let boldItalic = try #require(text.systemFace(weight: .bold, isItalic: true))

        for file in [regular, semibold, boldItalic] {
            #expect(file.data.prefix(4) == Data([0, 1, 0, 0]), "\(file.key)")
            #expect(try OpenTypeFont(file.data, faceIndex: file.faceIndex).isEmbeddable, "\(file.key)")
        }
        #expect(Set([regular.key, semibold.key, boldItalic.key]).count == 3)
    }

    /// The fonts DirectWrite falls back to for Japanese, which a PDF embeds so the text the screen shows is there: the
    /// runs cover the Japanese and only it, and each run's font has the glyphs.
    @Test("a line's Japanese falls back to a font that has it, and only the Japanese does", arguments: [true, false])
    func japaneseFallsBack(isSystemFace: Bool) throws {
        let text = try WindowsTextFonts(fontFiles: ScoreSurface.bundledFontFiles)
        let line = "Lead 余白計画 ソプラノ"
        let spans = text.fallback(ScorePDFTextLine(
            text: line, isSystemFace: isSystemFace, weight: isSystemFace ? .semibold : .regular, isItalic: false,
        ))
        let units = Array(line.utf16)
        let covered = Set(spans.flatMap(\.utf16Range))

        #expect(!spans.isEmpty)
        // A space between Japanese words may ride along in the fallback's run; the Latin letters never do.
        for (offset, unit) in units.enumerated() where unit != 0x20 {
            #expect(covered.contains(offset) == (unit > 0x2FFF), "U+\(String(unit, radix: 16)) at \(offset)")
        }
        for span in spans {
            let font = try OpenTypeFont(span.font.data, faceIndex: span.font.faceIndex)
            for unit in units[span.utf16Range] where unit > 0x2FFF {
                #expect(font.glyph(for: UInt32(unit)) != 0, "\(span.font.key) lacks U+\(String(unit, radix: 16))")
            }
        }
        #expect(text.fallback(ScorePDFTextLine(text: "Piano", isSystemFace: true, weight: .regular, isItalic: false))
            .isEmpty)
    }
}
