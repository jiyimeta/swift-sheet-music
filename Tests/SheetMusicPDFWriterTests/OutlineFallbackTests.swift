import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicLayout
@testable import SheetMusicPDFWriter
import Testing

/// A character no embeddable font covers, drawn as the outline the host's text engine gives for it — what Android
/// needs, whose CJK system faces are CFF and so never embedded — while it stays invisible text the PDF can be searched
/// for.
struct OutlineFallbackTests {
    /// 余 (U+4F59): Edwin has no glyph for it.
    private static let missing: Unicode.Scalar = "\u{4F59}"

    /// A unit square, the simplest closed contour.
    private static let square = ScorePDFGlyphOutline(elements: [
        .move(x: 0, y: 0), .line(x: 1, y: 0), .line(x: 1, y: 1), .line(x: 0, y: 1), .close,
    ])

    private static func text(_ string: String) -> DrawCommand {
        .text(text: string, x: 10, y: 20, size: 5, fontId: .textRoman)
    }

    /// The translation of the `Tm` that places the invisible character — where its outline must be filled.
    private static func invisiblePen(in content: String) throws -> String {
        let marker = try #require(content.range(of: " Tm 3 Tr"))
        let before = content[..<marker.lowerBound].split(separator: " ")
        return before.suffix(2).joined(separator: " ")
    }

    @Test func `a character no font covers is filled as the host's outline at its pen, and stays searchable`() throws {
        let walked = try WriterFixtures.walk([Self.text("A余B")], outlines: { scalar, _ in
            scalar == Self.missing ? Self.square : nil
        })
        let pen = try Self.invisiblePen(in: walked.content)

        #expect(walked.content.components(separatedBy: " f Q").count == 2)
        // The font size in points (5 mm), at the character's own pen position, after the text object.
        #expect(walked.content.contains("ET\nq 14.173 0 0 14.173 \(pen) cm 0 0 m 1 0 l 1 1 l 0 1 l h f Q\n"))
        // Still the text: its invisible code, which the face's ToUnicode maps back to the character.
        #expect(walked.content.components(separatedBy: "3 Tr").count == 2)
        let roman = walked.resources.font(.textRoman, style: DrawCommand.TextStyleFlag.none)
        #expect(roman.used.values.contains([Self.missing.value]))
    }

    @Test func `with no outline the text is written exactly as before`() throws {
        let plain = try WriterFixtures.walk([Self.text("A余B")])
        let none = try WriterFixtures.walk([Self.text("A余B")], outlines: { _, _ in nil })
        let empty = try WriterFixtures.walk([Self.text("A余B")], outlines: { _, _ in
            ScorePDFGlyphOutline(elements: [])
        })

        #expect(none.content == plain.content)
        #expect(empty.content == plain.content)
        #expect(!plain.content.contains(" f Q"))
    }

    @Test func `a fallback file that has the character wins over the outline`() throws {
        let asked = AskedScalars()
        let japanese = SyntheticTrueType.make(postScriptName: "Synthetic-JP", scalars: Array("余".utf16))
        let walked = try WriterFixtures.walk(
            [Self.text("A余B")],
            fallback: { _ in
                [ScorePDFFallbackSpan(utf16Range: 1 ..< 2, font: ScorePDFFontFile(key: "jp", data: japanese))]
            },
            outlines: { scalar, _ in
                asked.record(scalar)
                return Self.square
            },
        )

        #expect(!walked.content.contains(" f Q"))
        #expect(!walked.content.contains("3 Tr"))
        #expect(asked.scalars.isEmpty)
    }

    @Test func `the host is asked once per character and style`() throws {
        let asked = AskedScalars()
        _ = try WriterFixtures.walk(
            [
                Self.text("余余"), Self.text("余"), .setTextStyle(flags: DrawCommand.TextStyleFlag.bold),
                Self.text("余"),
            ],
            outlines: { scalar, style in
                asked.record(scalar, style)
                return Self.square
            },
        )

        #expect(asked.scalars == [Self.missing, Self.missing])
        #expect(asked.styles.map(\.weight) == [.regular, .bold])
        #expect(asked.styles.allSatisfy { !$0.isSystemFace && !$0.isItalic })
    }

    /// A PDF has no quadratic curve: it is raised to the cubic with the same shape.
    @Test func `a quadratic curve is drawn as its cubic`() {
        let outline = ScorePDFGlyphOutline(elements: [.move(x: 0, y: 0), .quad(cx: 1, cy: 1, x: 2, y: 0), .close])

        #expect(PDFPageWalker.pathOperators(outline) == "0 0 m 0.667 0.667 1.333 0.667 2 0 c h")
    }
}

/// The characters and styles the writer asked the host about, in order.
private final class AskedScalars: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [(Unicode.Scalar, ScorePDFTextStyle?)] = []

    var scalars: [Unicode.Scalar] {
        lock.withLock { asked.map(\.0) }
    }

    var styles: [ScorePDFTextStyle] {
        lock.withLock { asked.compactMap(\.1) }
    }

    func record(_ scalar: Unicode.Scalar, _ style: ScorePDFTextStyle? = nil) {
        lock.withLock { asked.append((scalar, style)) }
    }
}
