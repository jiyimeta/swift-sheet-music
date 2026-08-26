#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicLayout
    import Testing

    /// Regression guard for the Android dynamics-rendering bug: standard
    /// dynamics (p, mf, ff, sfz, …) must emit bold Bravura SMuFL glyphs,
    /// NOT Edwin text. Before the fix the bridge routed every dynamic
    /// through `emitText`, which emitted the literal letters in the text
    /// font — the iOS path already mapped them to glyphs via
    /// `DynamicSymbolMap` (now shared in `SheetMusicLayout`).
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
    }
#endif
