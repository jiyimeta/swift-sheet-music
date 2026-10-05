import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicLayout
@testable import SheetMusicPDF
@testable import SheetMusicPDFWriter
import Testing

/// The platform UI face in a PDF: the notation labels the layout measured in Segoe UI drawn from the file the host
/// hands over — embedded as TrueType — at the offsets the provider measured them at, and in Edwin when there is no file
/// the license lets a document carry.
struct SystemFaceTests {
    private static let semibold = DrawCommand.TextStyleFlag.semibold

    private static func fontNames(_ content: String) -> [Substring] {
        content.split(separator: "\n").map { $0.split(separator: " ")[1] }
    }

    @Test func `a TrueType file reads its license, slant and PostScript name`() throws {
        let font = try OpenTypeFont(SyntheticTrueType.make(postScriptName: "Synthetic-Italic", italicAngle: -12))

        #expect(!font.hasCFFOutlines)
        #expect(font.postScriptName == "Synthetic-Italic")
        #expect(font.italicAngle == -12)
        #expect(font.isEmbeddable)
        #expect(font.glyph(for: 0x41) != 0)
    }

    /// Restricted-license alone forbids it, and so does bitmap-only; preview-and-print or editable lifts restricted.
    @Test(arguments: [
        (UInt16(0x0000), true), (0x0004, true), (0x0008, true), (0x0002, false), (0x000A, true), (0x0208, false),
    ])
    func `the license decides whether a file may be embedded`(fsType: UInt16, embeddable: Bool) throws {
        #expect(try OpenTypeFont(SyntheticTrueType.make(fsType: fsType)).isEmbeddable == embeddable)
    }

    @Test func `system text draws in the host's file at the offsets the layout measured`() throws {
        let file = SyntheticTrueType.make()
        let font = try OpenTypeFont(file)
        let offsets = try WriterFixtures.tableProvider()
            .caretOffsets(text: "Piano", font: LayoutFont(face: "", pointSize: 4, weight: .semibold))
            .map { Double($0) }
        let letterI = PDFString.hex4(UInt16(font.glyph(for: 0x69)))
        let k = PDFPageWalker.pointsPerMM

        let walked = try WriterFixtures.walk(
            [.setTextStyle(flags: Self.semibold), .text(text: "Piano", x: 10, y: 20, size: 4, fontId: .system)],
            system: { weight, isItalic in weight == .semibold && !isItalic ? file : nil },
        )

        let second = PDFPageWalker.number((10 + offsets[1]) * k)
        #expect(walked.content.hasPrefix("BT /F6 11.339 Tf 1 0 0 1 28.346 785.197 Tm <"))
        #expect(walked.content.contains("1 0 0 1 \(second) 785.197 Tm <\(letterI)>"))
    }

    @Test func `without a file the license lets it embed, system text draws in Edwin`() throws {
        let restricted = SyntheticTrueType.make(fsType: 0x0002)
        let hosts: [@Sendable (FontWeight, Bool) -> Data?] = [{ _, _ in nil }, { _, _ in restricted }, { _, _ in
            Data("not a font".utf8)
        }]
        for host in hosts {
            let walked = try WriterFixtures.walk(
                [.setTextStyle(flags: Self.semibold), .text(text: "A", x: 10, y: 10, size: 5, fontId: .system)],
                system: host,
            )

            #expect(Self.fontNames(walked.content) == ["/F2"])
        }
    }

    @Test func `styles the host resolves to one file share one embedding, asked once each`() throws {
        let file = SyntheticTrueType.make()
        let asked = AskedStyles()
        func text() -> DrawCommand {
            .text(text: "A", x: 10, y: 10, size: 5, fontId: .system)
        }

        let walked = try WriterFixtures.walk(
            [
                .setTextStyle(flags: Self.semibold), text(), .setTextStyle(flags: DrawCommand.TextStyleFlag.bold),
                text(), .setTextStyle(flags: Self.semibold), text(),
            ],
            system: { weight, isItalic in
                asked.record(weight, isItalic)
                return file
            },
        )

        #expect(Self.fontNames(walked.content) == ["/F6", "/F6", "/F6"])
        #expect(asked.styles == ["semibold", "bold"])
    }

    @Test func `the document embeds the file as TrueType under its PostScript name, its text searchable`() throws {
        let file = SyntheticTrueType.make(postScriptName: "Synthetic-Semibold")
        let font = try OpenTypeFont(file)
        let page = EncodablePage(widthMM: 210, heightMM: 297, commands: [
            .setTextStyle(flags: Self.semibold), .text(text: "Piano", x: 10, y: 20, size: 4, fontId: .system),
        ])

        let pdf = try FontMetrics.$scopedProvider.withValue(WriterFixtures.tableProvider()) {
            try ScorePDFWriter.write([page], fonts: WriterFixtures.fonts(system: { _, _ in file }), title: nil)
        }
        // Byte for byte as Latin-1, so the ASCII dictionaries read as written whatever the streams hold.
        let objects = String(pdf.map { Character(Unicode.Scalar($0)) })
        let reader = try #require(PDFReaderDocument(data: pdf))
        let fonts = reader.pageFonts(page: 0)
        let cmap = try PDFImporter.ToUnicodeCMap.parse(data: #require(fonts.toUnicode["F6"]))
        let text = "Piano".unicodeScalars.compactMap { cmap.firstScalar(cid: UInt32(font.glyph(for: $0.value))) }

        #expect(objects.contains("/Subtype /CIDFontType2 /BaseFont /Synthetic-Semibold "))
        #expect(objects.contains("/CIDToGIDMap /Identity"))
        #expect(objects.contains("/FontFile2 "))
        #expect(objects.contains("<< /Length1 \(file.count) /Length "))
        #expect(!objects.contains("/FontFile3"))
        #expect(fonts.type0Names == ["F6"])
        #expect(String(String.UnicodeScalarView(text)) == "Piano")
    }
}

/// The styles the writer asked the host for, in order.
private final class AskedStyles: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []

    var styles: [String] {
        lock.withLock { asked }
    }

    func record(_ weight: FontWeight, _ isItalic: Bool) {
        lock.withLock { asked.append("\(weight)\(isItalic ? " italic" : "")") }
    }
}
