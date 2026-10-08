import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
import SheetMusicPages
@testable import SheetMusicPDF
import SheetMusicPDFSyntax
@testable import SheetMusicPDFWriter
import Testing

/// `ScorePDFWriter`: whole documents, read back by ssm's own Swift PDF reader — the reader folino's Windows and Android
/// imports use.
struct ScorePDFWriterTests {
    private static let titleAndClef: [DrawCommand] = [
        .text(text: "Prelude", x: 20, y: 30, size: 6, fontId: .textRoman),
        .glyph(codepoint: 0xE050, x: 20, y: 60, size: 7, fontId: .smufl),
    ]

    private static func write(_ pages: [EncodablePage], title: String? = "Prelude") throws -> Data {
        try FontMetrics.$scopedProvider.withValue(WriterFixtures.tableProvider()) {
            try ScorePDFWriter.write(pages, fonts: WriterFixtures.fonts(), title: title)
        }
    }

    private static func page(_ commands: [DrawCommand]) -> EncodablePage {
        EncodablePage(widthMM: 210, heightMM: 297, commands: commands)
    }

    /// Every stream whose dictionary says it is an OpenType font program, inflated.
    private static func fontPrograms(in file: Data) -> [Data] {
        let bytes = [UInt8](file)
        let marker = Array("/Subtype /OpenType".utf8)
        let start = Array("stream\n".utf8)
        let end = Array("\nendstream".utf8)
        var programs: [Data] = []
        var index = 0
        while let found = bytes[index...].firstRange(of: marker) {
            guard let open = bytes[found.upperBound...].firstRange(of: start),
                  let close = bytes[open.upperBound...].firstRange(of: end)
            else { break }
            if let inflated = try? PDFFlate.decode(Data(bytes[open.upperBound ..< close.lowerBound]), limit: 1 << 30) {
                programs.append(inflated)
            }
            index = close.upperBound
        }
        return programs
    }

    @Test func `the reader finds the page, both fonts, and the text through ToUnicode`() throws {
        let file = try Self.write([Self.page(Self.titleAndClef)])
        let reader = try #require(PDFReaderDocument(data: file))
        let fonts = reader.pageFonts(page: 0)
        let edwin = try BundledFonts.font("Edwin-Roman.otf")
        let roman = try #require(fonts.toUnicode["F2"])
        let cmap = PDFImporter.ToUnicodeCMap.parse(data: roman)

        let text = "Prelude".unicodeScalars.compactMap { scalar in
            cmap.firstScalar(cid: UInt32(edwin.glyph(for: scalar.value)))
        }

        #expect(reader.pageCount == 1)
        #expect(fonts.type0Names == ["F1", "F2"])
        #expect(String(String.UnicodeScalarView(text)) == "Prelude")
    }

    @Test func `each embedded program is the font file itself`() throws {
        let programs = try Self.fontPrograms(in: Self.write([Self.page(Self.titleAndClef)]))

        #expect(programs.count == 2)
        #expect(try programs.contains(BundledFonts.data("Bravura.otf")))
        #expect(try programs.contains(BundledFonts.data("Edwin-Roman.otf")))
    }

    /// Review Focus 4: a face is embedded once for the document, not once per page.
    @Test func `twenty-five pages embed each face once`() throws {
        let file = try Self.write(Array(repeating: Self.page(Self.titleAndClef), count: 25))
        let reader = try #require(PDFReaderDocument(data: file))

        #expect(reader.pageCount == 25)
        #expect(Self.fontPrograms(in: file).count == 2)
    }

    @Test func `the title reaches the document info in any script`() throws {
        let reader = try #require(PDFReaderDocument(data: Self.write([Self.page(Self.titleAndClef)], title: "前奏曲")))

        #expect(reader.documentAttributes?["Title"] as? String == "前奏曲")
    }

    /// Review Focus 5: a laid-out score written by the writer is music to ssm's own Swift reader — the notes come
    /// back, the round trip folino's import makes for a PDF that came from folino.
    @Test func `a laid-out score round-trips through the Swift reader`() throws {
        let provider = try WriterFixtures.tableProvider()
        let file = try FontMetrics.$scopedProvider.withValue(provider) {
            let score = try ScoreBridge.loadScore(bytes: Data(WriterFixtures.musicXML(measures: 8).utf8))
            let pages = ScorePages.compute(
                score: score, pageWidthMM: 210, pageHeightMM: 297, options: ScorePageOptions(mode: .page),
            )
            return try ScorePDFWriter.write(pages, fonts: WriterFixtures.fonts(), title: "Prelude")
        }

        let parsed = try PDFImporter.parseWithGeometryUsingSwiftReader(pdfData: file)

        #expect(WriterFixtures.soundingChords(parsed.score) == 32)
    }

    /// `drawsPageChrome` reaches the pages in `.page` mode only, and off is today's file byte for byte.
    @Test func `page chrome is written on sheets only, and off changes nothing`() throws {
        let provider = try WriterFixtures.tableProvider()
        let files = try FontMetrics.$scopedProvider.withValue(provider) {
            let score = try ScoreBridge.loadScore(bytes: Data(WriterFixtures.musicXML(measures: 64).utf8))
            let sheets = ScorePages.compute(
                score: score, pageWidthMM: 210, pageHeightMM: 297,
                options: ScorePageOptions(mode: .page, pageMarginsMM: .uniform(12.7)),
            )
            let scroll = ScorePages.compute(score: score, pageWidthMM: 210, pageHeightMM: 297)
            let fonts = try WriterFixtures.fonts()
            return try (
                plain: ScorePDFWriter.write(sheets, fonts: fonts, title: "Prelude"),
                off: ScorePDFWriter.write(sheets, fonts: fonts, title: "Prelude", drawsPageChrome: false),
                on: ScorePDFWriter.write(sheets, fonts: fonts, title: "Prelude", drawsPageChrome: true),
                pageCount: sheets.pageCount,
                scrollOff: ScorePDFWriter.write(scroll, fonts: fonts, title: "Prelude"),
                scrollOn: ScorePDFWriter.write(scroll, fonts: fonts, title: "Prelude", drawsPageChrome: true),
            )
        }

        #expect(files.pageCount > 1, "control: page numbers need a second page")
        #expect(files.off == files.plain)
        #expect(files.on != files.off)
        #expect(try #require(PDFReaderDocument(data: files.on)).pageCount == files.pageCount)
        #expect(files.scrollOn == files.scrollOff, "a scroll page has no margins to print chrome in")
    }
}
