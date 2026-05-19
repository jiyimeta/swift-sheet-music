import Foundation
@testable import SheetMusicAndroidJNI
import Testing

struct DrawProgramRoundTripTests {
    @Test
    func emptyDocumentRoundTrips() {
        let encoded = DrawProgramEncoder.encode(pages: [])
        var reader = BinaryReader(encoded)

        #expect(reader.read(UInt32.self) == DrawProgram.magic)
        #expect(reader.read(UInt32.self) == DrawProgram.version)
        #expect(reader.read(UInt32.self) == 0) // pageCount
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
        let encoded = DrawProgramEncoder.encode(pages: [page])
        let decoded = try DrawProgramDecoder.decode(encoded)

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
    func corruptMagicRaisesBadMagic() {
        var bytes = DrawProgramEncoder.encode(pages: [])
        bytes[0] = 0xFF
        #expect(throws: DrawProgramDecoder.DecodeError.self) {
            _ = try DrawProgramDecoder.decode(bytes)
        }
    }

    @Test
    func wrongVersionRaisesUnsupportedVersion() {
        var bytes = DrawProgramEncoder.encode(pages: [])
        bytes[4] = 0xFF // bump version byte
        #expect(throws: DrawProgramDecoder.DecodeError.self) {
            _ = try DrawProgramDecoder.decode(bytes)
        }
    }
}
