#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if canImport(CryptoKit)
        import CryptoKit
    #endif
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
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

        /// The payload-free terminator: a beam's four corners closed by `fillPath`, and a second
        /// path after it so a decoder that swallowed the case's framing would shift what follows.
        @Test
        func fillPathRoundTrips() throws {
            let page = EncodablePage(
                widthMM: 210, heightMM: 297,
                commands: [
                    .moveTo(x: 10, y: 20),
                    .lineTo(x: 40, y: 18),
                    .lineTo(x: 40, y: 18.5),
                    .lineTo(x: 10, y: 20.5),
                    .fillPath,
                    .moveTo(x: 1, y: 2),
                    .lineTo(x: 3, y: 4),
                    .stroke(width: 0.25),
                ],
            )
            let decoded = try DrawProgramCodec.decode(DrawProgramCodec.encode(pages: [page]))

            #expect(decoded == [page])
            #expect(decoded.first?.commands[4] == DrawCommand.fillPath)
        }

        @Test
        func systemFontRoundTrips() throws {
            let page = EncodablePage(
                widthMM: 100, heightMM: 100,
                commands: [
                    .text(text: "12", x: 10, y: 20, size: 3, fontId: .system),
                    .glyph(codepoint: 0x41, x: 1, y: 2, size: 3, fontId: .system),
                ],
            )
            let decoded = try DrawProgramCodec.decode(DrawProgramCodec.encode(pages: [page]))

            #expect(decoded == [page])
            if case let .text(_, _, _, _, fontId) = decoded.first?.commands[0] {
                #expect(fontId == .system)
            } else {
                Issue.record("expected text opcode at index 0")
            }
        }

        @Test
        func semiboldStyleRoundTrips() throws {
            let semibold = DrawCommand.TextStyleFlag.semibold
            let italic = DrawCommand.TextStyleFlag.italic
            let page = EncodablePage(
                widthMM: 100, heightMM: 100,
                commands: [
                    .setTextStyle(flags: semibold | italic),
                    .text(text: "Vln.", x: 10, y: 20, size: 3, fontId: .system),
                    .setTextStyle(flags: DrawCommand.TextStyleFlag.none),
                ],
            )
            let decoded = try DrawProgramCodec.decode(DrawProgramCodec.encode(pages: [page]))

            #expect(decoded == [page])
            if case let .setTextStyle(flags) = decoded.first?.commands[0] {
                #expect(flags == semibold | italic)
            } else {
                Issue.record("expected setTextStyle opcode at index 0")
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

        // MARK: - drawImage (v9)

        /// A kilobyte of bytes that are no image: the codec carries a picture's payload as it is.
        private static let kilobyte = Data((0 ..< 1024).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })

        @Test
        func drawImageRoundTripsMacroWire() throws {
            let page = EncodablePage(
                widthMM: 210, heightMM: 297,
                commands: [
                    .moveTo(x: 1, y: 2),
                    .drawImage(data: Self.kilobyte, x: 10.5, y: 20.25, w: 30, h: 15),
                    // After the picture, so a decoder that mis-framed its payload would shift what follows.
                    .lineTo(x: 3, y: 4),
                    .stroke(width: 0.25),
                ],
            )
            let decoded = try DrawProgramCodec.decode(DrawProgramCodec.encode(pages: [page]))

            #expect(decoded == [page])
            if case let .drawImage(data, x, y, w, h) = decoded.first?.commands[1] {
                #expect(data == Self.kilobyte)
                #expect([x, y, w, h] == [10.5, 20.25, 30, 15])
            } else {
                Issue.record("expected drawImage at index 1")
            }
        }

        /// The compatibility story: neither format can step over a command it does not know, so a reader refuses a
        /// stream of another version by its version word rather than mis-parsing it — v8 against the v9 macro reader,
        /// SMDF v2 against the v3 flat reader — and a v9 stream that carries a picture decodes under the v9 reader.
        @Test
        func readerRefusesAWrongVersion() throws {
            let v8 = DrawProgramWire(magic: DrawProgram.magic, version: 8, pages: []).encodeToData()
            #expect(throws: DrawProgramCodec.DecodeError.unsupportedVersion(8)) {
                try DrawProgramCodec.decode(v8)
            }

            var flat = DrawProgramFlat.encode(pages: [EncodablePage(widthMM: 1, heightMM: 1, commands: [.fillPath])])
            for (index, byte) in [UInt8(2), 0, 0, 0].enumerated() {
                flat[flat.startIndex + 4 + index] = byte
            }
            #expect(throws: DrawProgramFlat.DecodeError.unsupportedVersion(2)) {
                try DrawProgramFlat.decode(flat)
            }

            let picture = EncodablePage(
                widthMM: 1, heightMM: 1, commands: [.drawImage(data: Self.kilobyte, x: 0, y: 0, w: 1, h: 1)],
            )
            #expect(try DrawProgramCodec.decode(DrawProgramCodec.encode(pages: [picture])) == [picture])
        }

        // MARK: - Byte stability

        /// SHA-256 of the v8 macro encoding of `textFreeScore()`'s pages, recorded before v9 existed. A score without a
        /// box or a picture must draw the same commands, byte for byte, whatever the version word says.
        private static let textFreeProgramSHA256 = "bc6303383ffec755f8827cd6863a425aee1405182ccf34ca1273be7b55880a9d"

        /// Three whole-note bars on one staff: no title, no lyrics, no staff text, no instrument name — nothing whose
        /// position depends on a system font's measurement, so the hash pins the encoder and not the machine's fonts.
        private static func textFreeScore() -> Score {
            let measures = (0 ..< 3).map { index in
                Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 60 + index, tpc: 14)])),
                ])])
            }
            return Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: measures)])],
            )
        }

        /// Prints the v9 macro-wire bytes of one page holding a single `drawImage`, as base64, for the Kotlin
        /// `DrawProgramReaderTest` (`SWIFT_V9_IMAGE_PROGRAM_BASE64`). Off unless `SM_PRINT_KOTLIN_FIXTURE=1`.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["SM_PRINT_KOTLIN_FIXTURE"] == "1"))
        func printKotlinImageFixture() {
            let data = Data((0 ..< 12).map { UInt8($0) })
            let page = EncodablePage(
                widthMM: 210, heightMM: 297,
                commands: [.drawImage(data: data, x: 12.5, y: 20.25, w: 30, h: 15.75)],
            )
            let encoded = DrawProgramCodec.encode(pages: [page])
            print("W7-T12-B64:" + encoded.base64EncodedString())
        }

        #if canImport(CryptoKit)
            @Test
            func programWithoutImagesIsByteStable() {
                _ = TestSupport.installFontMetrics
                let pages = LayoutBridge.computeWithPages(
                    score: Self.textFreeScore(), pageWidthMM: 210, pageHeightMM: 297, options: .verticalDefault,
                ).pages
                let bytes = DrawProgramWire(magic: DrawProgram.magic, version: 8, pages: pages).encodeToData()
                let hex = SHA256.hash(data: bytes).map { byte in
                    let digits = String(byte, radix: 16)
                    return digits.count == 1 ? "0" + digits : digits
                }.joined()
                #expect(hex == Self.textFreeProgramSHA256, "W7-T9-SHA: \(hex)")
            }
        #endif
    }
#endif
