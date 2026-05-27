import Foundation
@testable import SheetMusicAndroidJNI
import Testing
import Wirelet

struct DrawProgramRoundTripTests {
    @Test
    func emptyDocumentRoundTrips() throws {
        let encoded = DrawProgramCodec.encode(pages: [])
        // Verify round-trip via the public API: decode must return an empty page list.
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
                    text: "Allegro",
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
    func corruptMagicRaisesBadMagic() throws {
        // Encode a draw program with a wrong magic value to verify that
        // DrawProgramCodec.decode raises .badMagic. We build the wire struct
        // directly with an invalid magic so the TLV layer parses cleanly but
        // the semantic check fires.
        let wrongMagicBytes = DrawProgramWire(
            magic: 0xDEAD_BEEF,
            version: DrawProgram.version,
            pages: [],
        ).encodeToData()
        #expect(throws: DrawProgramCodec.DecodeError.self) {
            _ = try DrawProgramCodec.decode(wrongMagicBytes)
        }
    }

    @Test
    func wrongVersionRaisesUnsupportedVersion() throws {
        // Encode a draw program with a wrong version value.
        let wrongVersionBytes = DrawProgramWire(
            magic: DrawProgram.magic,
            version: DrawProgram.version + 1,
            pages: [],
        ).encodeToData()
        #expect(throws: DrawProgramCodec.DecodeError.self) {
            _ = try DrawProgramCodec.decode(wrongVersionBytes)
        }
    }
}
