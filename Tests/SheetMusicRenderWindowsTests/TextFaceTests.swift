import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicLayout
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
        let regular = try #require(windowsSystemFontFile(weight: .regular, isItalic: false))
        let semibold = try #require(windowsSystemFontFile(weight: .semibold, isItalic: false))
        let boldItalic = try #require(windowsSystemFontFile(weight: .bold, isItalic: true))

        for file in [regular, semibold, boldItalic] {
            #expect(file.prefix(4) == Data([0, 1, 0, 0]))
        }
        #expect(Set([regular, semibold, boldItalic]).count == 3)
    }
}
