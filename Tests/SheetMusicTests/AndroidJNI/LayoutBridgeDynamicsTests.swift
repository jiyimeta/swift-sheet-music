#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// Regression guard for the Android dynamics-rendering bug: standard
    /// dynamics (p, mf, ff, sfz, …) must emit bold Bravura SMuFL glyphs,
    /// NOT Edwin text. Before the fix the bridge routed every dynamic
    /// through `emitText`, which emitted the literal letters in the text
    /// font — the iOS path already mapped them to glyphs via
    /// `DynamicSymbolMap` (now shared in `SheetMusicLayout`).
    ///
    /// A dynamic with its own text reaches the draw program with the opcodes it already had — each word run a `.text`
    /// inside its own `setTextStyle`, each `<sym>` a SMuFL `.glyph` at the layout's run position — measured with the
    /// portable table provider Android and the web read.
    struct LayoutBridgeDynamicsTests {
        private let _installApple = TestSupport.installApple

        private func emit(_ text: String) -> [DrawCommand] {
            var out: [DrawCommand] = []
            LayoutBridge.emitDynamic(
                text: text, originX: 0, originY: 0, sp: 10, into: &out,
            )
            return out
        }

        @Test("Standard dynamic 'mf' emits two SMuFL glyphs, no text")
        func standardDynamicEmitsGlyphs() {
            let out = emit("mf")
            let glyphs = out.compactMap { cmd -> (UInt32, DrawProgram.FontID)? in
                if case let .glyph(cp, _, _, _, fontId) = cmd { return (cp, fontId) }
                return nil
            }
            #expect(glyphs.count == 2)
            #expect(glyphs.allSatisfy { $0.1 == .smufl })
            #expect(glyphs.map(\.0) == [
                SMuFLCodepoint.dynamicMezzo, SMuFLCodepoint.dynamicForte,
            ])
            // No Edwin/text run for a symbol dynamic.
            let hasText = out.contains { if case .text = $0 { return true }; return false }
            #expect(!hasText)
        }

        @Test("'ff' emits two forte glyphs")
        func fortissimoEmitsForteGlyphs() {
            let cps = emit("ff").compactMap { cmd -> UInt32? in
                if case let .glyph(cp, _, _, _, _) = cmd { return cp }
                return nil
            }
            #expect(cps == [SMuFLCodepoint.dynamicForte, SMuFLCodepoint.dynamicForte])
        }

        @Test("Glyphs advance left-to-right (second glyph is further right)")
        func glyphsAdvanceRightward() {
            let xs = emit("mf").compactMap { cmd -> Double? in
                if case let .glyph(_, x, _, _, _) = cmd { return x }
                return nil
            }
            #expect(xs.count == 2)
            #expect(xs[1] > xs[0])
        }

        @Test("Free-form dynamic 'cresc.' falls back to text, no glyphs")
        func textDynamicFallsBack() {
            let out = emit("cresc.")
            let hasGlyph = out.contains { if case .glyph = $0 { return true }; return false }
            #expect(!hasGlyph)
            let textFonts = out.compactMap { cmd -> DrawProgram.FontID? in
                if case let .text(_, _, _, _, fontId) = cmd { return fontId }
                return nil
            }
            #expect(!textFonts.isEmpty)
            #expect(textFonts.allSatisfy { $0 == .textRoman })
        }

        private static let mm = LayoutBridge.ptToMMScale

        private static func tableProvider() throws -> any FontMetricsProvider {
            let url = try #require(TestResources.url(forResource: "sheet-music", withExtension: "smft"))
            return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: url)))
        }

        private static func render() throws -> (document: LayoutDocument, commands: [DrawCommand]) {
            let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("dynamics"))
            return try FontMetrics.$scopedProvider.withValue(tableProvider()) {
                let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1200)
                return (document, LayoutBridge.buildCommands(layout: document))
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

        @Test("words are italic text runs and the glyph a SMuFL glyph, at the layout's run position")
        func wordsAndGlyphsAreRuns() throws {
            let (document, commands) = try Self.render()
            let drawn = Self.drawn(commands)
            #expect(drawn.contains(.text("più ", DrawCommand.TextStyleFlag.italic)))
            #expect(drawn.contains(.glyph(SMuFLCodepoint.dynamicForte)))
            var found: (origin: CGPoint, rich: LayoutRichText)?
            for system in document.systems {
                for measure in system.measures where measure.measureIndex == 2 {
                    for case let .textMark(.dynamic, _, origin, rich?) in measure.elements {
                        found = (
                            CGPoint(
                                x: measure.origin.x + system.origin.x + origin.x,
                                y: measure.origin.y + system.origin.y + origin.y,
                            ),
                            rich,
                        )
                    }
                }
            }
            let (origin, rich) = try #require(found)
            let runs = rich.positionedRuns(at: origin, anchor: LayoutRichText.anchor(for: .dynamic))
            let symbol = try #require(runs.last)
            let x = Double(symbol.baseline.x) * Self.mm
            let y = Double(symbol.baseline.y) * Self.mm
            #expect(commands.contains { command in
                guard case let .glyph(codepoint, cx, cy, _, _) = command else { return false }
                return codepoint == SMuFLCodepoint.dynamicForte && abs(cx - x) < 0.001 && abs(cy - y) < 0.001
            })
        }

        @Test("a dynamic printing its subtype is still its glyphs")
        func plainDynamicIsItsGlyphs() throws {
            let drawn = try Self.drawn(Self.render().commands)
            #expect(drawn.contains(.glyph(SMuFLCodepoint.dynamicPiano)))
            #expect(!drawn.contains(.text("p", DrawCommand.TextStyleFlag.italic)))
        }
    }
#endif
