#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    import Testing

    /// Pins the committed metrics table against the CoreText provider it was
    /// generated from.
    ///
    /// The table is the layout engine's only source of font geometry in the
    /// browser. A silently empty or mis-scaled one does not fail anything — it
    /// engraves, just wrongly — so the failure it would otherwise cause is a human
    /// noticing that the spacing looks off, weeks later.
    @Suite("Shipped metrics table")
    struct ShippedMetricsTableTests {
        private let _installApple = TestSupport.installApple

        /// The committed table, resolved relative to this file so the test does not
        /// depend on the working directory a runner happens to use.
        private static let tableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Web/sheet-music-web/assets/sheet-music.smft")

        /// The copy the non-Apple test shapes install through `TestResources`,
        /// since WASI can reach the resource bundle and not the web package.
        private static let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicTests
            .appendingPathComponent("Resources/sheet-music.smft")

        /// noteheadBlack, gClef, fClef, restQuarter — no score renders without them.
        private static let essentialGlyphs: [UInt32] = [0xE0A4, 0xE050, 0xE062, 0xE4E5]

        /// A rehearsal mark's "A", a lyric's "g" with its descender, the digits a
        /// tempo mark counts in, and the space that separates two words — the
        /// shapes every text width in the engraver is built out of.
        private static let essentialTextGlyphs: [UInt32] = [0x0041, 0x0067, 0x0031, 0x0020]

        private static let textFace = "Edwin"

        @Test("the committed table decodes and covers the common glyphs")
        func committedTableDecodes() throws {
            let table = try FontMetricsTable.decode(Data(contentsOf: Self.tableURL))
            #expect(table.referenceSize == 1000)
            let bravura = try #require(table.face(named: SMuFLFamily.bravura))
            #expect(bravura.entries.count > 1000)
            for codepoint in Self.essentialGlyphs {
                let entry = try #require(
                    bravura.entries[codepoint],
                    "missing U+\(String(codepoint, radix: 16, uppercase: true))",
                )
                #expect(entry.advance > 0)
                #expect(entry.bboxW > 0)
                #expect(entry.bboxH > 0)
            }
            let edwin = try #require(table.face(named: Self.textFace))
            #expect(edwin.entries.count > 500)
            for codepoint in Self.essentialTextGlyphs {
                let entry = try #require(
                    edwin.entries[codepoint],
                    "missing U+\(String(codepoint, radix: 16, uppercase: true))",
                )
                #expect(entry.advance > 0)
            }
            // A space is an advance with no ink; every other text glyph here
            // has both, and a table that stored a bbox for the space would be
            // padding rehearsal-mark frames.
            #expect(edwin.entries[0x0020]?.bboxW == 0)
            #expect(try #require(edwin.entries[0x0041]).bboxW > 0)
        }

        /// Regenerating from a different provider — or from a face that failed to
        /// register, which resolves to the system font — would drift silently
        /// otherwise. The tolerance is half a point at a 1000 pt reference size,
        /// which is the `Float` rounding the table's storage imposes and nothing
        /// more.
        @available(macOS 15.0, *)
        @Test("the table agrees with the CoreText provider it was generated from")
        func tableAgreesWithCoreText() throws {
            let table = try FontMetricsTable.decode(Data(contentsOf: Self.tableURL))
            try #require(BravuraFont.register)
            let provider = AppleFontMetricsProvider()
            for (faceName, codepoints) in [
                (BravuraFont.familyName, Self.essentialGlyphs),
                (Self.textFace, Self.essentialTextGlyphs),
            ] {
                let face = try #require(table.face(named: faceName))
                let font = LayoutFont(face: faceName, pointSize: 1000)
                // The vertical metrics are what centre articulations, fermatas and
                // breath marks and what set every text row's Y on the platforms
                // that install a table; a table regenerated from a font that failed
                // to register would carry the system font's.
                #expect(abs(face.ascent - Double(provider.ascent(font: font))) < 0.5)
                #expect(abs(face.descent - Double(provider.descent(font: font))) < 0.5)
                #expect(abs(face.leading - Double(provider.leading(font: font))) < 0.5)
                for codepoint in codepoints {
                    let entry = try #require(face.entries[codepoint])
                    let scalar = try #require(Unicode.Scalar(codepoint))
                    let advance = provider.typographicWidth(
                        text: String(scalar), font: font,
                    )
                    #expect(abs(entry.advance - Double(advance)) < 0.5)
                    guard let bbox = provider.glyphPathBoundingBox(
                        font: font, codepoint: UInt16(codepoint),
                    ) else {
                        // Mapped but blank — a space. The entry exists for its
                        // advance and stores a zero box.
                        #expect(entry.bboxW == 0)
                        #expect(entry.bboxH == 0)
                        continue
                    }
                    #expect(abs(entry.bboxW - Double(bbox.width)) < 0.5)
                    #expect(abs(entry.bboxH - Double(bbox.height)) < 0.5)
                    #expect(abs(entry.bboxY - Double(bbox.minY)) < 0.5)
                }
            }
        }

        /// The whole point of measuring the text face: a rehearsal mark's frame,
        /// a harmony's width and a lyric's width used to come off
        /// `StubFontMetricsProvider.advanceEm`'s buckets — 0.65 em for every
        /// uppercase letter, 0.5 em for every lowercase one — on Android and in
        /// the browser.
        @Test("the table-backed provider serves measured text widths, not the buckets")
        func providerServesMeasuredTextWidths() throws {
            let table = try FontMetricsTable.decode(Data(contentsOf: Self.tableURL))
            let provider = makeFontMetricsTableProvider(table: table)
            let stub = StubFontMetricsProvider()
            let font = LayoutFont(face: Self.textFace, pointSize: 100)
            // "Ill" is where a bucket estimate is worst: three letters the stub
            // calls 0.65 / 0.5 / 0.5 em and Edwin draws far narrower.
            let measured = provider.typographicWidth(text: "Ill", font: font)
            let bucketed = stub.typographicWidth(text: "Ill", font: font)
            #expect(measured > 0)
            #expect(abs(Double(measured - bucketed)) > 10)
            // Leading is 0 for every provider that has no table; Edwin asks for
            // 0.2 em and a multi-line box is a whole line gap short without it.
            #expect(provider.leading(font: font) > 0)
        }

        /// The provider the browser installs must actually serve the table rather
        /// than falling through to the stub, or generating it bought nothing.
        @Test("the table-backed provider serves Bravura rather than the stub")
        func providerServesTheTable() throws {
            let table = try FontMetricsTable.decode(Data(contentsOf: Self.tableURL))
            let provider = makeFontMetricsTableProvider(table: table)
            let stub = StubFontMetricsProvider()
            let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: 40)
            let noteheadBlack: UInt16 = 0xE0A4
            let fromTable = try #require(
                provider.glyphPathBoundingBox(font: font, codepoint: noteheadBlack),
            )
            let fromStub = try #require(
                stub.glyphPathBoundingBox(font: font, codepoint: noteheadBlack),
            )
            #expect(fromTable.width != fromStub.width)
            #expect(fromTable.width > 0)
        }

        /// `Tests/SheetMusicTests/Resources/sheet-music.smft` exists only because
        /// WASI cannot read the web package's copy. Two tables that drift apart
        /// would have the wasm suite passing against geometry the browser never
        /// ships.
        @Test("the test fixture is a byte-for-byte copy of the shipped table")
        func fixtureIsACopyOfTheShippedTable() throws {
            let shipped = try Data(contentsOf: Self.tableURL)
            let fixture = try Data(contentsOf: Self.fixtureURL)
            #expect(fixture == shipped)
        }
    }
#endif
