// Tests/SheetMusicPDFWriterTests/PDFPageAnnotationTests.swift
import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicPDF
import SheetMusicPDFSyntax
@testable import SheetMusicPDFWriter
import Testing
#if canImport(PDFKit)
    import PDFKit
#endif

/// Page annotations in a new file: `/Ink` and `/Highlight` with their appearances, and nothing at all without them.
struct PDFPageAnnotationTests {
    static let page = EncodablePage(widthMM: 210, heightMM: 297, commands: [
        .text(text: "Prelude", x: 20, y: 30, size: 6, fontId: .textRoman),
        .glyph(codepoint: 0xE050, x: 20, y: 60, size: 7, fontId: .smufl),
    ])

    static func write(_ annotations: [Int: [PDFPageAnnotation]] = [:], pages: Int = 1) throws -> Data {
        try FontMetrics.$scopedProvider.withValue(WriterFixtures.tableProvider()) {
            try ScorePDFWriter.write(
                Array(repeating: page, count: pages), fonts: WriterFixtures.fonts(), title: "Prelude",
                annotations: annotations,
            )
        }
    }

    static func fnv1a(_ data: Data) -> UInt64 {
        data.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }

    /// 4.4.0's bytes, fingerprinted before annotations existed: a file without them must not move by a byte.
    @Test func `without annotations the file is 4.4.0's byte for byte`() throws {
        #expect(try Self.fnv1a(Self.write(pages: 2)) == 13_369_278_125_582_008_218)
    }

    static let red = PDFRGB(red: 1, green: 0, blue: 0)

    /// A 10-point square stroke, its center line along the top edge, at `(x, y)` displayed.
    static func ink(
        x: Double = 100, y: Double = 200, clip: PDFClipPath? = nil, opacity: Double = 1,
    ) -> PDFPageAnnotation {
        .ink(PDFInkAnnotation(
            inkList: [[PDFPagePoint(x: x, y: y), PDFPagePoint(x: x + 10, y: y)]], width: 2, color: red,
            opacity: opacity,
            appearance: [[
                PDFPagePoint(x: x, y: y), PDFPagePoint(x: x + 10, y: y), PDFPagePoint(x: x + 10, y: y + 10),
                PDFPagePoint(x: x, y: y + 10),
            ]],
            clip: clip,
        ))
    }

    static func text(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Every Form XObject's content, inflated, in file order.
    static func appearances(in file: Data) -> [String] {
        let bytes = [UInt8](file)
        var found: [String] = []
        var index = 0
        while let form = bytes[index...].firstRange(of: Array("/Subtype /Form".utf8)),
              let open = bytes[form.upperBound...].firstRange(of: Array("stream\n".utf8)),
              let close = bytes[open.upperBound...].firstRange(of: Array("\nendstream".utf8))
        {
            if let inflated = try? PDFFlate.decode(Data(bytes[open.upperBound ..< close.lowerBound]), limit: 1 << 30),
               let content = String(data: inflated, encoding: .utf8)
            {
                found.append(content)
            }
            index = close.upperBound
        }
        return found
    }

    @Test func `an ink annotation is written on its page with its appearance`() throws {
        let file = try Self.write([1: [Self.ink(opacity: 0.5)]], pages: 2)
        let text = Self.text(file)
        // A4 is 841.89 points tall: displayed y 200 is user y 641.89.
        #expect(text.contains("/Subtype /Ink"))
        #expect(text.contains("/InkList [[100 641.89 110 641.89]]"))
        #expect(text.contains("/BS << /W 2 >>"))
        #expect(text.contains("/C [1 0 0]"))
        #expect(text.contains("/CA 0.5"))
        #expect(text.contains("/ca 0.5 /CA 0.5"))
        #expect(text.contains("/Rect [99 630.89 111 642.89]"))
        #expect(text.components(separatedBy: "/Annots [").count == 2) // the second page only
        let appearance = try #require(Self.appearances(in: file).first)
        #expect(appearance.contains("100 641.89 m"))
        #expect(appearance.contains("f\n"))
        #expect(!appearance.contains(" W "))
    }

    @Test func `a clipped stroke draws inside its mask only`() throws {
        let clip = PDFClipPath(elements: [
            .move(PDFPagePoint(x: 100, y: 200)), .line(PDFPagePoint(x: 105, y: 200)),
            .quad(PDFPagePoint(x: 105, y: 205), PDFPagePoint(x: 100, y: 210)), .close,
        ], evenOdd: true)
        let appearance = try #require(Self.appearances(in: Self.write([0: [Self.ink(clip: clip)]])).first)
        // The quad's control point (105, 205) becomes two cubic controls two thirds of the way from each end.
        #expect(appearance.contains("105 641.89 l\n105 638.556 103.333 635.223 100 631.89 c\nh\nW* n"))
    }

    /// Review Focus 4: an empty mask shows nothing, and `W n` without a path is a broken file.
    @Test func `a stroke erased to nothing or drawing nothing is left out`() throws {
        let erased = PDFClipPath(elements: [], evenOdd: false)
        guard case var .ink(empty) = Self.ink() else { return }
        empty.appearance = []
        let text = try Self.text(Self.write([0: [Self.ink(clip: erased), .ink(empty)]]))
        #expect(!text.contains("/Annots"))
        #expect(!text.contains("/Subtype /Ink"))
    }

    @Test func `a highlight multiplies an opaque color over its rectangle`() throws {
        let band = PDFPageAnnotation.highlight(PDFHighlightAnnotation(
            rect: PDFPageRect(x: 50, y: 100, width: 200, height: 40), color: PDFRGB(red: 1, green: 0.9, blue: 0.5),
        ))
        let file = try Self.write([0: [band]])
        let text = Self.text(file)
        #expect(text.contains("/Subtype /Highlight"))
        #expect(text.contains("/QuadPoints [50 741.89 250 741.89 50 701.89 250 701.89]"))
        #expect(text.contains("/BM /Multiply"))
        #expect(try #require(Self.appearances(in: file).first).contains("1 0.9 0.5 rg"))
    }

    #if canImport(PDFKit)
        /// Apple's reader opens the file and finds the annotations as what they are, on the pages they were put on.
        @Test func `PDFKit reads the ink and the highlight back`() throws {
            let band = PDFPageAnnotation.highlight(PDFHighlightAnnotation(
                rect: PDFPageRect(x: 50, y: 100, width: 200, height: 40), color: Self.red,
            ))
            let document = try #require(PDFDocument(data: Self.write([0: [band], 1: [Self.ink()]], pages: 2)))
            let first = try #require(document.page(at: 0)).annotations
            let second = try #require(document.page(at: 1)).annotations
            #expect(first.map(\.type) == ["Highlight"])
            #expect(second.map(\.type) == ["Ink"])
            let bounds = try #require(second.first).bounds
            #expect(abs(bounds.minX - 99) < 0.01 && abs(bounds.maxY - 642.89) < 0.01)
        }
    #endif

    @Test func `out of range indices and empty pages allocate no annotation objects`() throws {
        #expect(try Self.write([-1: [Self.ink()], 2: [Self.ink()]], pages: 2) == Self.write(pages: 2))
        #expect(try Self.write([0: []], pages: 2) == Self.write(pages: 2))
    }

    @Test func `degenerate figures and highlights are omitted`() throws {
        guard case var .ink(ink) = Self.ink() else { return }
        ink.appearance = [[PDFPagePoint(x: 0, y: 0), PDFPagePoint(x: 1, y: 1)]]
        let highlight = PDFPageAnnotation.highlight(PDFHighlightAnnotation(
            rect: PDFPageRect(x: 0, y: 0, width: 0, height: 10), color: Self.red,
        ))
        #expect(try Self.write([0: [.ink(ink), highlight]]) == Self.write())
    }

    @Test func `a cubic clip uses the nonzero rule and close returns to the subpath start`() throws {
        let clip = PDFClipPath(elements: [
            .move(PDFPagePoint(x: 100, y: 200)),
            .cubic(PDFPagePoint(x: 101, y: 202), PDFPagePoint(x: 103, y: 204), PDFPagePoint(x: 105, y: 206)),
            .close,
            .quad(PDFPagePoint(x: 100, y: 203), PDFPagePoint(x: 100, y: 206)),
        ], evenOdd: false)
        let appearance = try #require(Self.appearances(in: Self.write([0: [Self.ink(clip: clip)]])).first)
        #expect(appearance.contains("101 639.89 103 637.89 105 635.89 c\nh\n100 639.89 100 637.89 100 635.89 c\nW n"))
    }
}
