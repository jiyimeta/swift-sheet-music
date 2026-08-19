import Foundation
@testable import SheetMusicBridgeCore
@testable import SheetMusicCore
import Testing

@Suite("DrawProgramFlat")
struct DrawProgramFlatTests {
    /// One page carrying every opcode, so a mis-slotted field in any single
    /// case shows up as a round-trip failure rather than as a rendering bug
    /// nobody notices until the browser draws it.
    private var allOpcodesPage: EncodablePage {
        EncodablePage(
            widthMM: 210,
            heightMM: 297,
            commands: [
                .moveTo(x: 1, y: 2),
                .lineTo(x: 3, y: 4),
                .stroke(width: 0.5),
                .fillRect(x: 5, y: 6, w: 7, h: 8),
                .glyph(codepoint: 0xE050, x: 9, y: 10, size: 11, fontId: .smufl),
                .text(text: "Allegro", x: 12, y: 13, size: 14, fontId: .textRoman),
                .setColor(argb: 0xFF00_7AFF),
                .cubicTo(cx1: 15, cy1: 16, cx2: 17, cy2: 18, x: 19, y: 20),
                .stretchedGlyph(
                    codepoint: 0xE000, rightEdgeX: 21, topY: 22, bottomY: 23,
                    fontSize: 24, xScale: 1.5, fontId: .smufl,
                ),
                .setRotation(radians: 1.5707963267948966, pivotX: 25, pivotY: 26),
                .setDash(onMM: 0.75, offMM: 0.25),
                .italicText(text: "3", x: 27, y: 28, size: 29, fontId: .textRoman),
            ],
        )
    }

    @Test("round-trips every opcode")
    func roundTripsEveryOpcode() throws {
        let pages = [allOpcodesPage]
        let decoded = try DrawProgramFlat.decode(DrawProgramFlat.encode(pages: pages))
        #expect(decoded == pages)
    }

    @Test("round-trips multiple pages")
    func roundTripsMultiplePages() throws {
        let pages = [allOpcodesPage, EncodablePage(widthMM: 100, heightMM: 50, commands: [])]
        let decoded = try DrawProgramFlat.decode(DrawProgramFlat.encode(pages: pages))
        #expect(decoded == pages)
    }

    @Test("round-trips an empty page list")
    func roundTripsEmpty() throws {
        #expect(try DrawProgramFlat.decode(DrawProgramFlat.encode(pages: [])).isEmpty)
    }

    @Test("agrees with the v6 encoding for the same pages")
    func agreesWithV6() throws {
        let pages = [allOpcodesPage]
        let viaV6 = try DrawProgramCodec.decode(DrawProgramCodec.encode(pages: pages))
        let viaFlat = try DrawProgramFlat.decode(DrawProgramFlat.encode(pages: pages))
        #expect(viaFlat == viaV6)
    }

    /// The string side table is deduplicated, so two commands carrying the same
    /// run share one entry. If interning ever regressed to append-per-command
    /// the payload would still decode — this pins the size, which is the only
    /// observable difference.
    @Test("interns repeated strings once")
    func internsRepeatedStrings() throws {
        let once = EncodablePage(
            widthMM: 10, heightMM: 10,
            commands: [.text(text: "dolce", x: 0, y: 0, size: 1, fontId: .textRoman)],
        )
        let twice = EncodablePage(
            widthMM: 10, heightMM: 10,
            commands: [
                .text(text: "dolce", x: 0, y: 0, size: 1, fontId: .textRoman),
                .text(text: "dolce", x: 2, y: 2, size: 1, fontId: .textRoman),
            ],
        )
        let growth = DrawProgramFlat.encode(pages: [twice]).count
            - DrawProgramFlat.encode(pages: [once]).count
        #expect(growth == DrawProgramFlat.commandStride)
        #expect(try DrawProgramFlat.decode(DrawProgramFlat.encode(pages: [twice])) == [twice])
    }

    @Test("rejects a bad magic")
    func rejectsBadMagic() {
        var bytes = DrawProgramFlat.encode(pages: [allOpcodesPage])
        bytes[bytes.startIndex] = 0x00
        #expect(throws: DrawProgramFlat.DecodeError.self) {
            try DrawProgramFlat.decode(bytes)
        }
    }

    @Test("rejects an unsupported version")
    func rejectsUnsupportedVersion() {
        var bytes = DrawProgramFlat.encode(pages: [allOpcodesPage])
        bytes[bytes.index(bytes.startIndex, offsetBy: 4)] = 0xFE
        #expect(throws: DrawProgramFlat.DecodeError.self) {
            try DrawProgramFlat.decode(bytes)
        }
    }

    @Test("truncation throws rather than mis-parsing")
    func rejectsTruncation() {
        let bytes = DrawProgramFlat.encode(pages: [allOpcodesPage])
        #expect(throws: DrawProgramFlat.DecodeError.self) {
            try DrawProgramFlat.decode(bytes.prefix(bytes.count - 1))
        }
    }

    @Test("computeWithPages agrees with computeWithDocument")
    func computeWithPagesAgrees() {
        // `LayoutEngine.layout` asserts that the CoreText provider is installed
        // on a CoreText-capable platform, and this is the one test here that
        // engraves rather than round-tripping a hand-built page.
        _ = TestSupport.installApple
        let score = Score(
            division: 480,
            metaTags: ["workTitle": "flat"],
            titleFrame: ScoreFrame(heightSp: 10, texts: [FrameText(style: .title, text: "flat")]),
        )
        let viaPages = LayoutBridge.computeWithPages(
            score: score, pageWidthMM: 210, pageHeightMM: 297, options: .verticalDefault,
        )
        let viaDocument = LayoutBridge.computeWithDocument(
            score: score, pageWidthMM: 210, pageHeightMM: 297, options: .verticalDefault,
        )
        #expect(DrawProgramCodec.encode(pages: viaPages.pages) == viaDocument.encoded)
    }
}
