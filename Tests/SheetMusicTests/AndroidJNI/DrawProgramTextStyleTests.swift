#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The draw program had no way to say "bold". MuseScore's own role defaults
    /// (`TextStyleType.museScoreDefault`) set tempo marks, rehearsal marks and instrument-change
    /// text bold, and the Apple renderer applies them through `ResolvedTextStyle.font` — so the same
    /// score read bold on iOS and regular weight everywhere the bridge drew it.
    ///
    /// Worse than a weight difference on its own: a rehearsal mark's frame is sized from the
    /// measured text, so a renderer that *could* draw bold from a table that could not measure it
    /// would push the letters through the box. Style and metrics land together for that reason.
    @Suite("DrawProgram text style")
    struct DrawProgramTextStyleTests {
        private let _installApple = TestSupport.installApple

        private static let bold = DrawCommand.TextStyleFlag.bold
        private static let italic = DrawCommand.TextStyleFlag.italic
        private static let neutral = DrawCommand.TextStyleFlag.none

        private static func styleRuns(_ commands: [DrawCommand]) -> [UInt8] {
            commands.compactMap { if case let .setTextStyle(flags) = $0 { flags } else { nil } }
        }

        // MARK: - Role → flags

        /// The mapping the whole change rests on, asserted against the roles MuseScore actually
        /// styles rather than a made-up one.
        @Test(arguments: [
            (TextStyleType.tempo, bold),
            (.rehearsalMark, bold),
            (.instrumentChange, bold),
            (.dynamics, italic),
            (.chordSymbolB, italic),
            (.glissando, italic),
            (.staffText, neutral),
            (.lyricsOdd, neutral),
        ])
        func styleFlagsFollowTheMuseScoreDefaults(style: TextStyleType, expected: UInt8) {
            #expect(LayoutBridge.styleFlags(for: style) == expected)
        }

        /// Only bold changes what gets measured. Italic advances match the upright ones closely
        /// enough that no provider distinguishes them, and asking for a weight nothing measures
        /// would silently fall back anyway.
        @Test(arguments: [
            (TextStyleType.tempo, FontWeight.bold),
            (.rehearsalMark, .bold),
            (.dynamics, .regular),
            (.staffText, .regular),
        ])
        func measurementWeightFollowsBoldOnly(style: TextStyleType, expected: FontWeight) {
            #expect(LayoutBridge.measurementWeight(for: style) == expected)
        }

        // MARK: - Emission

        /// A styled run is bracketed: set the style, draw, restore. The restore is what keeps the
        /// state opcode from leaking into whatever the encoder emits next.
        @Test
        func aStyledRunIsBracketedByTheStateOpcode() {
            var out: [DrawCommand] = []
            LayoutBridge.emitText(
                text: "Allegro", style: .tempo, originX: 10, originY: 20, sp: 7, into: &out,
            )
            #expect(Self.styleRuns(out) == [Self.bold, Self.neutral])
            // …and the text itself sits between them, not before or after.
            let setIndex = out.firstIndex { if case .setTextStyle = $0 { true } else { false } }
            let clearIndex = out.lastIndex { if case .setTextStyle = $0 { true } else { false } }
            let textIndex = out.firstIndex { if case .text = $0 { true } else { false } }
            #expect(setIndex != nil && clearIndex != nil && textIndex != nil)
            if let setIndex, let clearIndex, let textIndex {
                #expect(setIndex < textIndex)
                #expect(textIndex < clearIndex)
            }
        }

        /// An unstyled role emits no state opcode at all, so a score with no bold or italic text
        /// produces byte-identical bytes to what it did before v7 — which is what keeps the existing
        /// draw-program goldens meaningful.
        @Test
        func anUnstyledRunEmitsNoStateOpcode() {
            var out: [DrawCommand] = []
            LayoutBridge.emitText(
                text: "cantabile", style: .staffText, originX: 10, originY: 20, sp: 7, into: &out,
            )
            #expect(Self.styleRuns(out).isEmpty)
        }

        /// The rehearsal mark is the case that motivated the whole change: bold text inside a frame
        /// sized from the measured text.
        @Test
        func theRehearsalMarkIsBold() {
            var out: [DrawCommand] = []
            LayoutBridge.encodeRehearsalMark(
                text: "A", originX: 10, originY: 20, frame: .rectangle, color: nil, sp: 7,
                into: &out,
            )
            #expect(Self.styleRuns(out) == [Self.bold, Self.neutral])
        }

        /// The tuplet digit was the one place already drawing italic, through the superseded
        /// `italicText` opcode. It moves to the state opcode so there is one style channel and not
        /// two.
        @Test
        func theTupletLabelUsesTheStateOpcodeRatherThanItalicText() {
            var out: [DrawCommand] = []
            LayoutBridge.encodeTupletBracket(
                fromX: 0, fromY: 0, toX: 40, toY: 0, text: "3", hasBracket: true, isAbove: true,
                sp: 7, into: &out,
            )
            #expect(Self.styleRuns(out).contains(Self.italic))
            #expect(!out.contains { if case .italicText = $0 { true } else { false } })
        }

        /// `italicText` stays in the enum for wire stability, but nothing emits it any more. A new
        /// emit site belongs in `setTextStyle`.
        @Test
        func nothingEmitsTheSupersededItalicTextOpcode() {
            var out: [DrawCommand] = []
            for style in [TextStyleType.tempo, .dynamics, .staffText, .glissando] {
                LayoutBridge.emitText(
                    text: "x", style: style, originX: 0, originY: 0, sp: 7, into: &out,
                )
            }
            #expect(!out.contains { if case .italicText = $0 { true } else { false } })
        }

        // MARK: - Wire

        @Test
        func theVersionIsSeven() {
            #expect(DrawProgram.version == 7)
        }

        /// Both encodings — the `@WireFormatChoice` one the JNI bridge uses and the flat
        /// fixed-stride one the browser reads — have to carry the new opcode, or one consumer sees
        /// a style the other does not.
        @Test
        func theStateOpcodeSurvivesTheChoiceEncoding() throws {
            let page = EncodablePage(
                widthMM: 210, heightMM: 297,
                commands: [
                    .setTextStyle(flags: Self.bold | Self.italic),
                    .text(text: "A", x: 1, y: 2, size: 3, fontId: .textRoman),
                    .setTextStyle(flags: Self.neutral),
                ],
            )
            let decoded = try DrawProgramCodec.decode(DrawProgramCodec.encode(pages: [page]))
            #expect(decoded == [page])
        }

        @Test
        func theStateOpcodeSurvivesTheFlatEncoding() throws {
            let page = EncodablePage(
                widthMM: 210, heightMM: 297,
                commands: [
                    .setTextStyle(flags: Self.bold),
                    .text(text: "A", x: 1, y: 2, size: 3, fontId: .textRoman),
                    .setTextStyle(flags: Self.neutral),
                ],
            )
            let decoded = try DrawProgramFlat.decode(DrawProgramFlat.encode(pages: [page]))
            #expect(decoded == [page])
        }

        /// The mask is a bitmask, not an enum: both traits can be live at once, and a third costs no
        /// wire change.
        @Test
        func boldAndItalicCombine() {
            #expect(Self.bold | Self.italic == 3)
            #expect(Self.neutral == 0)
        }

        // MARK: - Metrics

        /// A bold request resolves the `"-Bold"` record when the table has one.
        @Test
        func aBoldRequestPrefersTheBoldRecord() {
            let table = Self.table(withBold: true)
            #expect(table.face(for: LayoutFont(face: "Edwin", pointSize: 10, weight: .bold))?
                .name == "Edwin-Bold")
        }

        /// …and falls back to the regular record when it does not. This is the compatibility claim
        /// that lets the convention ship without an SMFT version bump: a table written before the
        /// bold record existed answers exactly as it always did.
        @Test
        func aBoldRequestFallsBackToTheRegularRecord() {
            let table = Self.table(withBold: false)
            #expect(table.face(for: LayoutFont(face: "Edwin", pointSize: 10, weight: .bold))?
                .name == "Edwin")
        }

        /// A regular request never picks up the bold record, even when one is present.
        @Test
        func aRegularRequestIgnoresTheBoldRecord() {
            let table = Self.table(withBold: true)
            #expect(table.face(for: LayoutFont(face: "Edwin", pointSize: 10))?.name == "Edwin")
        }

        /// Face names are matched case-insensitively — a score's `<font face="…">` is author text —
        /// and the bold suffix has to follow the same rule or `"edwin"` would silently lose its
        /// bold record.
        @Test
        func theBoldLookupIsCaseInsensitive() {
            let table = Self.table(withBold: true)
            #expect(table.face(for: LayoutFont(face: "edwin", pointSize: 10, weight: .bold))?
                .name == "Edwin-Bold")
        }

        private static func table(withBold: Bool) -> FontMetricsTable {
            func face(_ name: String) -> FontMetricsTable.Face {
                FontMetricsTable.Face(
                    name: name, ascent: 1, descent: 1, leading: 0, entries: [:],
                )
            }
            var faces = ["edwin": face("Edwin")]
            if withBold { faces["edwin-bold"] = face("Edwin-Bold") }
            return FontMetricsTable(referenceSize: 100, faces: faces)
        }
    }
#endif
