import Foundation
@testable import SheetMusicAndroidJNI
import SheetMusicWireFormat
import Testing

struct DrawProgramRoundTripTests {
    @Test
    func emptyDocumentRoundTrips() throws {
        let encoded = DrawProgramCodec.encode(pages: [])
        var reader = WireFormatReader(data: encoded)

        #expect(try reader.readInteger(UInt32.self) == DrawProgram.magic)
        #expect(try reader.readInteger(UInt32.self) == DrawProgram.version)
        #expect(try reader.readInteger(Int32.self) == 0) // pageCount

        let pages = try DrawProgramCodec.decode(encoded)
        #expect(pages.isEmpty)
    }

    @Test
    func singlePageWithLineAndGlyphRoundTrips() throws {
        let page = EncodablePage(
            widthMM: 210, heightMM: 297,
            commands: [
                .moveTo(x: 20, y: 40),
                .lineTo(x: 190, y: 40),
                .stroke(width: 0.5),
                .glyph(
                    codepoint: 0xE050,
                    x: 30,
                    y: 60,
                    size: 24,
                    fontId: .smufl,
                ), // gClef
            ],
        )
        let encoded = DrawProgramCodec.encode(pages: [page])
        let decoded = try DrawProgramCodec.decode(encoded)

        #expect(decoded.count == 1)
        #expect(decoded[0].widthMM == 210)
        #expect(decoded[0].heightMM == 297)
        #expect(decoded[0].commands.count == 4)
        if case let .glyph(codepoint, x, y, size, fontId) = decoded[0].commands[3] {
            #expect(codepoint == 0xE050)
            #expect(x == 30)
            #expect(y == 60)
            #expect(size == 24)
            #expect(fontId == .smufl)
        } else {
            Issue.record("expected glyph opcode at index 3")
        }
    }

    @Test
    func textCommandRoundTrips() throws {
        let page = EncodablePage(
            widthMM: 100, heightMM: 100,
            commands: [
                .text(
                    "Allegro",
                    x: 10, y: 20,
                    size: 12,
                    fontId: .textRoman,
                ),
            ],
        )
        let encoded = DrawProgramCodec.encode(pages: [page])
        let decoded = try DrawProgramCodec.decode(encoded)

        #expect(decoded.count == 1)
        if case let .text(s, x, y, size, fontId) = decoded[0].commands[0] {
            #expect(s == "Allegro")
            #expect(x == 10)
            #expect(y == 20)
            #expect(size == 12)
            #expect(fontId == .textRoman)
        } else {
            Issue.record("expected text opcode at index 0")
        }
    }

    @Test
    func corruptMagicRaisesBadMagic() {
        var bytes = DrawProgramCodec.encode(pages: [])
        bytes[0] = 0xFF
        #expect(throws: DrawProgramCodec.DecodeError.self) {
            _ = try DrawProgramCodec.decode(bytes)
        }
    }

    @Test
    func wrongVersionRaisesUnsupportedVersion() {
        var bytes = DrawProgramCodec.encode(pages: [])
        bytes[4] = 0xFF // bump version byte
        #expect(throws: DrawProgramCodec.DecodeError.self) {
            _ = try DrawProgramCodec.decode(bytes)
        }
    }
}
