#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    import Testing

    /// Pins the committed metrics table against the CoreText provider it was
    /// generated from.
    ///
    /// The table is the layout engine's only source of Bravura geometry in the
    /// browser. A silently empty or mis-scaled one does not fail anything — it
    /// engraves, just wrongly — so the failure it would otherwise cause is a human
    /// noticing that the spacing looks off, weeks later.
    @Suite("Bravura metrics table")
    struct BravuraMetricsTableTests {
        /// The committed table, resolved relative to this file so the test does not
        /// depend on the working directory a runner happens to use.
        private static let tableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Web/sheet-music-web/assets/bravura.smft")

        /// noteheadBlack, gClef, fClef, restQuarter — no score renders without them.
        private static let essentialGlyphs: [UInt32] = [0xE0A4, 0xE050, 0xE062, 0xE4E5]

        @Test("the committed table decodes and covers the common glyphs")
        func committedTableDecodes() throws {
            let table = try SMuFLMetricsTable.decode(Data(contentsOf: Self.tableURL))
            #expect(table.referenceSize == 1000)
            #expect(table.entries.count > 1000)
            for codepoint in Self.essentialGlyphs {
                let entry = try #require(
                    table.entries[codepoint],
                    "missing U+\(String(codepoint, radix: 16, uppercase: true))",
                )
                #expect(entry.advance > 0)
                #expect(entry.bboxW > 0)
                #expect(entry.bboxH > 0)
            }
        }

        /// Regenerating from a different provider — or from a Bravura that failed to
        /// register, which resolves to the system font — would drift silently
        /// otherwise. The tolerance is half a point at a 1000 pt reference size,
        /// which is the `Float` rounding the table's storage imposes and nothing
        /// more.
        @available(macOS 15.0, *)
        @Test("the table agrees with the CoreText provider it was generated from")
        func tableAgreesWithCoreText() throws {
            let table = try SMuFLMetricsTable.decode(Data(contentsOf: Self.tableURL))
            _ = TestSupport.installApple
            try #require(BravuraFont.register)
            let provider = AppleFontMetricsProvider()
            let font = LayoutFont(face: BravuraFont.familyName, pointSize: 1000)
            for codepoint in Self.essentialGlyphs {
                let entry = try #require(table.entries[codepoint])
                let scalar = try #require(Unicode.Scalar(codepoint))
                let advance = provider.typographicWidth(
                    text: String(Character(scalar)), font: font,
                )
                #expect(abs(entry.advance - Double(advance)) < 0.5)
                let bbox = try #require(
                    provider.glyphPathBoundingBox(font: font, codepoint: UInt16(codepoint)),
                )
                #expect(abs(entry.bboxW - Double(bbox.width)) < 0.5)
                #expect(abs(entry.bboxH - Double(bbox.height)) < 0.5)
                #expect(abs(entry.bboxY - Double(bbox.minY)) < 0.5)
            }
        }

        /// The provider the browser installs must actually serve the table rather
        /// than falling through to the stub, or generating it bought nothing.
        @Test("the table-backed provider serves Bravura rather than the stub")
        func providerServesTheTable() throws {
            let table = try SMuFLMetricsTable.decode(Data(contentsOf: Self.tableURL))
            let provider = makeSMuFLMetricsTableProvider(table: table)
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
    }
#endif
