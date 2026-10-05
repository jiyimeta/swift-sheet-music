import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicLayout
@testable import SheetMusicPDFWriter
import Testing

/// `PDFPageWalker`: each draw command as the operators it becomes on an A4 page (841.89 pt tall) — millimetres to
/// points (72 / 25.4), y flipped from the page's top to its bottom.
struct PDFPageWalkerTests {
    @Test func `a stroked line lands in points from the page's bottom at its own width`() throws {
        let walked = try WriterFixtures.walk([.moveTo(x: 10, y: 20), .lineTo(x: 30, y: 20), .stroke(width: 0.2)])

        #expect(walked.content == "28.346 785.197 m\n85.039 785.197 l\n0.567 w S\n")
    }

    @Test func `a filled rectangle is drawn from its bottom-left corner`() throws {
        let walked = try WriterFixtures.walk([.fillRect(x: 10, y: 20, w: 30, h: 40)])

        #expect(walked.content == "28.346 671.811 85.039 113.386 re f\n")
    }

    @Test func `a curve and a filled path keep their operators`() throws {
        let walked = try WriterFixtures.walk([
            .moveTo(x: 0, y: 0), .cubicTo(cx1: 10, cy1: 0, cx2: 10, cy2: 10, x: 0, y: 10), .fillPath,
        ])

        #expect(walked.content == "0 841.89 m\n28.346 841.89 28.346 813.543 0 813.543 c\nf\n")
    }

    @Test func `a translucent color paints through a graphics state, and the next color is opaque again`() throws {
        let walked = try WriterFixtures.walk([.setColor(argb: 0x80FF_0000), .setColor(argb: 0xFF00_0000)])
        let dictionary = try walked.resources.write(into: PDFObjectWriter())

        #expect(walked.content == "/GS128 gs 1 0 0 rg 1 0 0 RG\n/GS255 gs 0 0 0 rg 0 0 0 RG\n")
        #expect(dictionary.contains("/GS128 << /Type /ExtGState /ca 0.502 /CA 0.502 >>"))
        #expect(dictionary.contains("/GS255 << /Type /ExtGState /ca 1 /CA 1 >>"))
    }

    @Test func `a dash is set in points and cleared`() throws {
        let walked = try WriterFixtures.walk([.setDash(onMM: 1, offMM: 0.5), .setDash(onMM: 0, offMM: 0)])

        #expect(walked.content == "[2.835 1.417] 0 d\n[] 0 d\n")
    }

    /// A quarter turn about (100, 100) mm: the pivot maps to itself, and after the rotation ends the color and the
    /// dash `Q` restored are set again, so the state does not leak and is not lost.
    @Test func `a rotation is bracketed, and the state is set again after it`() throws {
        let walked = try WriterFixtures.walk([
            .setDash(onMM: 1, offMM: 0.5),
            .setRotation(radians: .pi / 2, pivotX: 100, pivotY: 100),
            .moveTo(x: 0, y: 0),
            .setRotation(radians: 0, pivotX: 0, pivotY: 0),
            .lineTo(x: 1, y: 1),
        ])

        #expect(walked.content.contains("q 0 -1 1 0 -274.961 841.89 cm\n"))
        #expect(walked.content.contains("Q\n/GS255 gs 0 0 0 rg 0 0 0 RG\n[2.835 1.417] 0 d\n2.835 839.055 l"))
    }

    @Test func `a rotation still open at the page's end is closed`() throws {
        let walked = try WriterFixtures.walk([.setRotation(radians: 0.5, pivotX: 0, pivotY: 0)])

        #expect(walked.content.hasSuffix(" cm\nQ\n"))
    }

    @Test func `a SMuFL glyph is shown in Bravura at its size, on its baseline`() throws {
        let bravura = try BundledFonts.font("Bravura.otf")
        let clef = PDFString.hex4(UInt16(bravura.glyph(for: 0xE050)))

        let walked = try WriterFixtures.walk([.glyph(codepoint: 0xE050, x: 20, y: 50, size: 7, fontId: .smufl)])

        #expect(walked.content == "BT /F1 19.843 Tf 56.693 700.157 Td <\(clef)> Tj ET\n")
    }

    @Test func `the text style picks Edwin's real faces`() throws {
        func text(_ fontId: DrawProgram.FontID) -> DrawCommand {
            .text(text: "A", x: 10, y: 10, size: 5, fontId: fontId)
        }
        let walked = try WriterFixtures.walk([
            .setTextStyle(flags: DrawCommand.TextStyleFlag.bold), text(.textRoman),
            .setTextStyle(flags: DrawCommand.TextStyleFlag.italic), text(.system),
            .setTextStyle(flags: DrawCommand.TextStyleFlag.semibold), text(.textRoman),
        ])
        let fonts = walked.content.split(separator: "\n").map { $0.split(separator: " ")[1] }

        #expect(fonts == ["/F3", "/F4", "/F2"])
    }

    /// Each character where the layout's provider measured it — not where the font's kerning would put it.
    @Test func `text characters sit at the measured offsets`() throws {
        let provider = try WriterFixtures.tableProvider()
        let offsets = provider.caretOffsets(text: "AV", font: LayoutFont(face: "Edwin", pointSize: 5))
            .map { Double($0) }
        let k = PDFPageWalker.pointsPerMM

        let walked = try WriterFixtures.walk([.text(text: "AV", x: 10, y: 20, size: 5, fontId: .textRoman)])

        #expect(walked.content.hasPrefix("BT /F2 14.173 Tf 1 0 0 1 28.346 785.197 Tm <"))
        #expect(walked.content.contains("1 0 0 1 \(PDFPageWalker.number((10 + offsets[1]) * k)) 785.197 Tm <"))
    }

    /// Review Focus 1: Edwin has no Japanese. The character draws nothing (invisible text) but keeps a code of its
    /// own past Edwin's glyphs, which `ToUnicode` names — so a search finds it.
    @Test func `a character Edwin lacks is invisible but keeps its text`() throws {
        let walked = try WriterFixtures.walk([.text(text: "A前", x: 10, y: 20, size: 5, fontId: .textRoman)])
        let edwin = try BundledFonts.font("Edwin-Roman.otf")
        let code = PDFString.hex4(UInt16(edwin.glyphCount))
        let roman = walked.resources.font(.textRoman, style: 0)

        #expect(walked.content.contains("Tm 3 Tr <\(code)> Tj 0 Tr"))
        #expect(roman.used[edwin.glyphCount] == [0x524D])
    }

    @Test func `a brace is stretched between its top and bottom with its right edge in place`() throws {
        let walked = try WriterFixtures.walk([.stretchedGlyph(
            codepoint: 0xE000, rightEdgeX: 20, topY: 30, bottomY: 80, fontSize: 7, xScale: 1, fontId: .smufl,
        )])
        let operators = walked.content.split(separator: " ")

        #expect(walked.content.hasPrefix("BT /F1 1 Tf "))
        // The matrix's vertical scale stretches the brace well past its natural size at 7 mm.
        let scaleY = try #require(Double(operators[7]))
        #expect(scaleY > 19.843)
    }
}
