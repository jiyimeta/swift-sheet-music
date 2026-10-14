#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The draw program carries a formatted text with the opcodes it already had: each text run a `.text` inside its
    /// own `setTextStyle` pair, each symbol a SMuFL `.glyph`, underline and strike stroked lines. Measured with the
    /// portable table provider Android and the web read.
    @Suite("LayoutBridge rich text")
    struct LayoutBridgeRichTextTests {
        /// Registers Edwin, which `LayoutEngine.layout` asserts a real provider for in DEBUG.
        private let _installApple = TestSupport.installApple

        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        private static func tableProvider() throws -> any FontMetricsProvider {
            let url = try #require(TestResources.url(forResource: "sheet-music", withExtension: "smft"))
            return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: url)))
        }

        private static func staffText(_ text: String, _ content: [PreservedTextMarkup.ContentItem]) -> StaffText {
            StaffText(text: text, preservedTextMarkup: PreservedTextMarkup(content: content, derivedText: text))
        }

        private static func commands(_ text: StaffText) throws -> [DrawCommand] {
            let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
            let score = Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
            )], systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .staffText(text), originalStaff: staff),
            ])])
            return try FontMetrics.$scopedProvider.withValue(tableProvider()) {
                LayoutBridge.buildCommands(
                    layout: LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800),
                )
            }
        }

        private enum Drawn: Equatable {
            case text(String, UInt8)
            case glyph(UInt32)
        }

        /// Each `.text` with the style bits in force, and each `.glyph`.
        private static func drawn(_ commands: [DrawCommand]) -> [Drawn] {
            var style = DrawCommand.TextStyleFlag.none
            var out: [Drawn] = []
            for command in commands {
                switch command {
                case let .setTextStyle(flags): style = flags
                case let .text(text, _, _, _, _): out.append(.text(text, style))
                case let .glyph(codepoint, _, _, _, _): out.append(.glyph(codepoint))
                default: break
                }
            }
            return out
        }

        /// The x of the first `.text` command whose string is `string`.
        private static func textX(_ string: String, in commands: [DrawCommand]) -> Double? {
            for command in commands {
                if case let .text(text, x, _, _, _) = command, text == string { return x }
            }
            return nil
        }

        private static func strokes(_ commands: [DrawCommand]) -> Int {
            commands.count { if case .stroke = $0 { true } else { false } }
        }

        @Test("a bold run draws inside its own setTextStyle, the rest in the style's weight")
        func boldRun() throws {
            let drawn = try Self.drawn(Self.commands(Self.staffText("Solo ad lib.", [
                .element(.init(name: "b", content: [.characters("Solo")])), .characters(" ad lib."),
            ])))
            #expect(drawn.contains(.text("Solo", DrawCommand.TextStyleFlag.bold)))
            #expect(drawn.contains(.text(" ad lib.", DrawCommand.TextStyleFlag.none)))
            #expect(!drawn.contains(.text("Solo ad lib.", DrawCommand.TextStyleFlag.none)))
        }

        @Test("a symbol run is a SMuFL glyph")
        func symbolRun() throws {
            let drawn = try Self.drawn(Self.commands(Self.staffText("senza ", [
                .characters("senza "), .element(.init(name: "sym", content: [.characters("keyboardPedalPed")])),
            ])))
            #expect(drawn.contains(.glyph(0xE650)))
            #expect(drawn.contains(.text("senza ", DrawCommand.TextStyleFlag.none)))
        }

        @Test("an underline is one more stroked line")
        func underline() throws {
            let plain = try Self.commands(Self.staffText("under", [
                .element(.init(name: "i", content: [.characters("under")])),
            ]))
            let underlined = try Self.commands(Self.staffText("under", [
                .element(.init(name: "u", content: [.characters("under")])),
            ]))
            #expect(Self.strokes(underlined) == Self.strokes(plain) + 1)
        }

        /// Task 9 draws a staff text's runs at anchor (0, 1): the ink's left edge sits at the element origin, which
        /// is also where the plain text's left edge sits (anchor x 0). So the first run starts where the plain draw
        /// started, and the next run follows it to the right by the first run's advance.
        @Test("a staff text's runs start at the origin the plain text started at, and follow left to right")
        func staffTextRunsKeepTheLayoutAnchor() throws {
            let plain = try Self.commands(StaffText(text: "Solo ad lib."))
            let rich = try Self.commands(Self.staffText("Solo ad lib.", [
                .element(.init(name: "b", content: [.characters("Solo")])), .characters(" ad lib."),
            ]))
            let plainX = try #require(Self.textX("Solo ad lib.", in: plain))
            let firstX = try #require(Self.textX("Solo", in: rich))
            let secondX = try #require(Self.textX(" ad lib.", in: rich))
            #expect(abs(firstX - plainX) < 0.01)
            #expect(secondX > firstX)
        }

        @Test("the stream keeps the v8 wire: nothing new to decode")
        func noNewOpcode() throws {
            let commands = try Self.commands(Self.staffText("Solo", [
                .element(.init(name: "b", content: [.characters("Solo")])),
            ]))
            let page = EncodablePage(widthMM: 100, heightMM: 100, commands: commands)
            let encoded = DrawProgramCodec.encode(pages: [page])
            #expect(try DrawProgramCodec.decode(encoded).first?.commands == commands)
            #expect(DrawProgram.version == 8)
        }
    }
#endif
