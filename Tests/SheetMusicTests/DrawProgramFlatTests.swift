import Foundation
@testable import SheetMusicBridgeCore
@testable import SheetMusicCore
import Testing

@Suite("DrawProgramFlat")
struct DrawProgramFlatTests {
    /// One page carrying every opcode (0…12, in order) and every font id, so a
    /// mis-slotted field in any single case shows up as a round-trip failure
    /// rather than as a rendering bug nobody notices until the browser draws it.
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
                .setTextStyle(flags: DrawCommand.TextStyleFlag.semibold | DrawCommand.TextStyleFlag.italic),
                .fillPath,
                // Tail: the system face, so every FontID crosses the encoder.
                .text(text: "12", x: 27, y: 28, size: 29, fontId: .system),
            ],
        )
    }

    /// Opcodes mirror `DrawCommand`'s declaration order, one record per command.
    private static let expectedOpcodes: [Int32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 5]

    @Test("the version is 2")
    func theVersionIsTwo() {
        #expect(DrawProgramFlat.version == 2)
    }

    @Test("round-trips every opcode")
    func roundTripsEveryOpcode() throws {
        let pages = [allOpcodesPage]
        let decoded = try DrawProgramFlat.decode(DrawProgramFlat.encode(pages: pages))
        #expect(decoded == pages)
    }

    /// The round trip alone would pass with two opcodes swapped in both directions; the web
    /// reader decodes the numbers, so pin them.
    @Test("writes the declaration-order opcodes 0…12")
    func writesDeclarationOrderOpcodes() throws {
        let page = allOpcodesPage
        let bytes = DrawProgramFlat.encode(pages: [page])
        let start = try Self.firstCommandOffset(bytes)
        let opcodes = (0 ..< page.commands.count).map { i in
            Self.readI32(bytes, at: start + i * DrawProgramFlat.commandStride)
        }
        #expect(opcodes == Self.expectedOpcodes)
    }

    /// `fillPath` carries nothing: zero slots and integer, no string, no font.
    @Test("fillPath writes an empty record")
    func fillPathRecordIsEmpty() throws {
        let bytes = DrawProgramFlat.encode(pages: [EncodablePage(widthMM: 1, heightMM: 1, commands: [.fillPath])])
        let start = try Self.firstCommandOffset(bytes)
        #expect(Self.readI32(bytes, at: start) == 12)
        for slot in 0 ..< 6 {
            #expect(Self.readU64(bytes, at: start + 4 + slot * 8) == 0)
        }
        #expect(Self.readI32(bytes, at: start + 52) == -1) // stringIndex
        #expect(Self.readI32(bytes, at: start + 56) == 0) // integer
        #expect(Self.readI32(bytes, at: start + 60) == -1) // fontId
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

    @Test("agrees with the macro encoding for the same pages")
    func agreesWithTheMacroEncoding() throws {
        let pages = [allOpcodesPage]
        let viaMacro = try DrawProgramCodec.decode(DrawProgramCodec.encode(pages: pages))
        let viaFlat = try DrawProgramFlat.decode(DrawProgramFlat.encode(pages: pages))
        #expect(viaFlat == viaMacro)
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

    /// A v1 stream numbers `setTextStyle` 12 and has no `fillPath`; reading it as v2 would
    /// mis-read both without a word, so the version gate has to refuse it.
    @Test("rejects a version 1 stream")
    func rejectsVersionOne() {
        var bytes = DrawProgramFlat.encode(pages: [allOpcodesPage])
        Self.writeI32(1, into: &bytes, at: 4)
        #expect(throws: DrawProgramFlat.DecodeError.unsupportedVersion(1)) {
            try DrawProgramFlat.decode(bytes)
        }
    }

    @Test("rejects opcode 13")
    func rejectsUnknownOpcode() throws {
        var bytes = DrawProgramFlat.encode(pages: [EncodablePage(widthMM: 1, heightMM: 1, commands: [.fillPath])])
        let opcodeOffset = try Self.firstCommandOffset(bytes)
        Self.writeI32(13, into: &bytes, at: opcodeOffset)
        #expect(throws: DrawProgramFlat.DecodeError.unknownOpcode(13)) {
            try DrawProgramFlat.decode(bytes)
        }
    }

    @Test("rejects font id 3")
    func rejectsUnknownFontID() throws {
        let page = EncodablePage(
            widthMM: 1, heightMM: 1,
            commands: [.text(text: "12", x: 0, y: 0, size: 1, fontId: .system)],
        )
        var bytes = DrawProgramFlat.encode(pages: [page])
        let fontIDOffset = try Self.firstCommandOffset(bytes) + DrawProgramFlat.commandStride - 4
        #expect(Self.readI32(bytes, at: fontIDOffset) == 2) // the system face, which decodes
        Self.writeI32(3, into: &bytes, at: fontIDOffset)
        #expect(throws: DrawProgramFlat.DecodeError.badFontID(3)) {
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
        _ = TestSupport.installFontMetrics
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

    // MARK: - Byte helpers

    /// Byte offset of page 0's first command record: the header, the string table, then page 0's
    /// width, height and command count.
    private static func firstCommandOffset(_ bytes: Data) throws -> Int {
        var offset = 12 // magic, version, pageCount
        let stringCount = Int(readI32(bytes, at: offset))
        offset += 4
        for _ in 0 ..< stringCount {
            offset += 4 + Int(readI32(bytes, at: offset))
        }
        offset += 8 + 8 + 4
        try #require(offset + DrawProgramFlat.commandStride <= bytes.count)
        return offset
    }

    private static func readI32(_ bytes: Data, at offset: Int) -> Int32 {
        var v: UInt32 = 0
        for i in 0 ..< 4 {
            v |= UInt32(bytes[bytes.startIndex + offset + i]) << (8 * i)
        }
        return Int32(bitPattern: v)
    }

    private static func readU64(_ bytes: Data, at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0 ..< 8 {
            v |= UInt64(bytes[bytes.startIndex + offset + i]) << (8 * i)
        }
        return v
    }

    private static func writeI32(_ value: Int32, into bytes: inout Data, at offset: Int) {
        let bits = UInt32(bitPattern: value)
        for i in 0 ..< 4 {
            bytes[bytes.startIndex + offset + i] = UInt8(truncatingIfNeeded: bits >> (8 * i))
        }
    }
}
