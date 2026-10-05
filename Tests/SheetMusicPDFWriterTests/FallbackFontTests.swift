import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicLayout
@testable import SheetMusicPDFWriter
import Testing

/// Characters a line's face lacks, drawn in the font the host's text engine falls back to for them (Japanese, in a
/// collection, on Windows), and the TrueType subset that keeps such a font — ten megabytes and more — to the glyphs a
/// document draws.
struct FallbackFontTests {
    /// A Japanese-capable stand-in: kana and kanji only, the second face of a collection.
    private static let japanese = SyntheticTrueType.collection([
        SyntheticTrueType.make(postScriptName: "Other-Face", scalars: Array("Z".utf16)),
        SyntheticTrueType.make(postScriptName: "Synthetic-JP", scalars: Array("余白計画ソプラノ".utf16)),
    ])

    private static func japaneseFile() -> ScorePDFFontFile {
        ScorePDFFontFile(key: "C:/fonts/synthetic.ttc", data: japanese, faceIndex: 1)
    }

    @Test func `a collection's face reads as its own font`() throws {
        let font = try OpenTypeFont(Self.japanese, faceIndex: 1)

        #expect(font.postScriptName == "Synthetic-JP")
        #expect(font.glyph(for: 0x4F59) != 0) // 余
        #expect(font.glyph(for: 0x5A) == 0)
        #expect(throws: OpenTypeFont.Malformed.self) { try OpenTypeFont(Self.japanese, faceIndex: 2) }
    }

    @Test func `a subset keeps the glyphs a composite is built from, and comes out a font of its own`() throws {
        let data = SyntheticTrueType.make(scalars: Array("ABC".utf16), composites: [(0x00C5, [1, 3])])
        let font = try OpenTypeFont(SyntheticTrueType.collection([SyntheticTrueType.make(), data]), faceIndex: 1)
        let composite = font.glyph(for: 0x00C5)

        let subset = try TrueTypeSubset.subset(font, keeping: [composite])
        let tables = SFNTTables.read(subset)

        #expect([UInt8](subset.prefix(4)) == [0, 1, 0, 0])
        #expect(Set(tables.keys) == ["OS/2", "glyf", "head", "hhea", "hmtx", "loca", "maxp"])
        #expect(!SFNTTables.glyph(composite, in: tables).isEmpty)
        #expect(!SFNTTables.glyph(1, in: tables).isEmpty)
        #expect(SFNTTables.glyph(2, in: tables).isEmpty)
        #expect(!SFNTTables.glyph(3, in: tables).isEmpty)
        #expect(!SFNTTables.glyph(0, in: tables).isEmpty)
        // The whole file sums to the magic `head.checkSumAdjustment` balances it to.
        #expect(TrueTypeSubset.checksum([UInt8](subset)) == 0xB1B0_AFBA)
        #expect(tables["head"]?[51] == 1) // long loca offsets
    }

    @Test func `a subset's tag is six capitals, the same for the same glyphs and not for others`() {
        let tag = PDFFontEmbedding.subsetTag([0, 3, 17])

        #expect(tag.count == 6)
        #expect(tag.allSatisfy { ("A" ... "Z").contains($0) })
        #expect(PDFFontEmbedding.subsetTag([0, 3, 17]) == tag)
        #expect(PDFFontEmbedding.subsetTag([0, 3, 18]) != tag)
    }

    @Test func `characters the face lacks draw in the host's fallback, and the line goes back to its face`() throws {
        let asked = AskedLines()
        let fallback = try OpenTypeFont(Self.japanese, faceIndex: 1)
        let edwin = try BundledFonts.font("Edwin-Roman.otf")
        let blank = PDFString.hex4(UInt16(fallback.glyph(for: 0x767D))) // 白

        let walked = try WriterFixtures.walk(
            [.text(text: "A余白B", x: 10, y: 20, size: 5, fontId: .textRoman)],
            fallback: { line in
                asked.record(line)
                return [ScorePDFFallbackSpan(utf16Range: 1 ..< 3, font: Self.japaneseFile())]
            },
        )
        let switches = walked.content.split(separator: " ").enumerated()
            .filter { $0.element == "Tf" }.map { walked.content.split(separator: " ")[$0.offset - 2] }

        #expect(switches == ["/F2", "/F6", "/F2"])
        #expect(walked.content.contains("<\(blank)> Tj"))
        #expect(!walked.content.contains("3 Tr"))
        #expect(asked.lines.map(\.text) == ["A余白B"])
        #expect(asked.lines.first?.isSystemFace == false)
        #expect(walked.content.contains("<\(PDFString.hex4(UInt16(edwin.glyph(for: 0x42))))> Tj"))
    }

    @Test func `a line is asked about once, and only when its face lacks a character`() throws {
        let asked = AskedLines()
        func text(_ string: String) -> DrawCommand {
            .text(text: string, x: 10, y: 20, size: 5, fontId: .textRoman)
        }

        _ = try WriterFixtures.walk([text("ソプラノ"), text("Alto"), text("ソプラノ")], fallback: { line in
            asked.record(line)
            return [ScorePDFFallbackSpan(utf16Range: 0 ..< 4, font: Self.japaneseFile())]
        })

        #expect(asked.lines.map(\.text) == ["ソプラノ"])
    }

    @Test func `a character neither the face nor its fallback has stays invisible text`() throws {
        let walked = try WriterFixtures.walk(
            [.text(text: "余漢", x: 10, y: 20, size: 5, fontId: .textRoman)],
            fallback: { _ in [ScorePDFFallbackSpan(utf16Range: 0 ..< 2, font: Self.japaneseFile())] },
        )

        #expect(walked.content.contains("/F6 14.173 Tf"))
        #expect(walked.content.components(separatedBy: "3 Tr").count == 2)
    }
}

/// The lines the writer asked the host about, in order.
private final class AskedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [ScorePDFTextLine] = []

    var lines: [ScorePDFTextLine] {
        lock.withLock { asked }
    }

    func record(_ line: ScorePDFTextLine) {
        lock.withLock { asked.append(line) }
    }
}
