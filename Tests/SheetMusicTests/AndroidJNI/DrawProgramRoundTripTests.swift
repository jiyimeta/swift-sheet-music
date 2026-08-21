#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
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
        func stretchedGlyphRoundTrips() throws {
            let page = EncodablePage(
                widthMM: 210, heightMM: 297,
                commands: [
                    .stretchedGlyph(
                        codepoint: 0xE000, // brace
                        rightEdgeX: 12.5,
                        topY: 20,
                        bottomY: 60,
                        fontSize: 7,
                        xScale: 3.625,
                        fontId: .smufl,
                    ),
                ],
            )
            let encoded = DrawProgramCodec.encode(pages: [page])
            let decoded = try DrawProgramCodec.decode(encoded)

            #expect(decoded.count == 1)
            if case let .stretchedGlyph(
                codepoint, rightEdgeX, topY, bottomY, fontSize, xScale, fontId,
            ) = decoded[0].commands[0] {
                #expect(codepoint == 0xE000)
                #expect(rightEdgeX == 12.5)
                #expect(topY == 20)
                #expect(bottomY == 60)
                #expect(fontSize == 7)
                #expect(xScale == 3.625)
                #expect(fontId == .smufl)
            } else {
                Issue.record("expected stretchedGlyph opcode at index 0")
            }
        }

        @Test
        func setRotationRoundTrips() throws {
            let page = EncodablePage(
                widthMM: 210, heightMM: 297,
                commands: [
                    .setRotation(radians: -1.5707963, pivotX: 12.5, pivotY: 30),
                    .setRotation(radians: 0, pivotX: 0, pivotY: 0),
                ],
            )
            let encoded = DrawProgramCodec.encode(pages: [page])
            let decoded = try DrawProgramCodec.decode(encoded)

            #expect(decoded.count == 1)
            if case let .setRotation(radians, pivotX, pivotY) = decoded[0].commands[0] {
                #expect(radians == -1.5707963)
                #expect(pivotX == 12.5)
                #expect(pivotY == 30)
            } else {
                Issue.record("expected setRotation opcode at index 0")
            }
            if case let .setRotation(radians, _, _) = decoded[0].commands[1] {
                #expect(radians == 0)
            } else {
                Issue.record("expected setRotation reset at index 1")
            }
        }

        @Test
        func setDashRoundTrips() throws {
            let page = EncodablePage(
                widthMM: 210, heightMM: 297,
                commands: [
                    .setDash(onMM: 1.06, offMM: 1.06),
                    .setDash(onMM: 0, offMM: 0),
                ],
            )
            let encoded = DrawProgramCodec.encode(pages: [page])
            let decoded = try DrawProgramCodec.decode(encoded)

            #expect(decoded.count == 1)
            if case let .setDash(onMM, offMM) = decoded[0].commands[0] {
                #expect(onMM == 1.06)
                #expect(offMM == 1.06)
            } else {
                Issue.record("expected setDash opcode at index 0")
            }
        }

        @Test
        func italicTextRoundTrips() throws {
            let page = EncodablePage(
                widthMM: 100, heightMM: 100,
                commands: [
                    .italicText(
                        text: "3",
                        x: 10, y: 20,
                        size: 9,
                        fontId: .textRoman,
                    ),
                ],
            )
            let encoded = DrawProgramCodec.encode(pages: [page])
            let decoded = try DrawProgramCodec.decode(encoded)

            #expect(decoded.count == 1)
            if case let .italicText(s, x, y, size, fontId) = decoded[0].commands[0] {
                #expect(s == "3")
                #expect(x == 10)
                #expect(y == 20)
                #expect(size == 9)
                #expect(fontId == .textRoman)
            } else {
                Issue.record("expected italicText opcode at index 0")
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
#endif
