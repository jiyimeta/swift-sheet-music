#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// A chord ornament reaches the draw program as ordinary glyph opcodes, so Android, Windows and the web draw it
    /// with no code of their own.
    @Suite("LayoutBridge ornament")
    struct LayoutBridgeOrnamentTests {
        private let _installApple = TestSupport.installApple

        private static func commands(_ ornaments: [ChordOrnament]) -> [DrawCommand] {
            LayoutBridge.buildCommands(layout: AnnotationFixtures.layout(AnnotationFixtures.score([
                .chord(Chord(duration: .half, notes: ChordNotes([Note(pitch: 72, tpc: 14)]), ornaments: ornaments)),
            ])))
        }

        private static func glyphs(_ commands: [DrawCommand]) -> [(codepoint: UInt32, size: Double)] {
            commands.compactMap { command in
                guard case let .glyph(codepoint, _, _, size, _) = command else { return nil }
                return (codepoint, size)
            }
        }

        @Test("a trill is its glyph, its accidental a smaller one")
        func trillWithAccidental() throws {
            let plain = Self.glyphs(Self.commands([]))
            let drawn = Self.glyphs(Self.commands([ChordOrnament(kind: .trill, accidentalAbove: .sharp)]))
            #expect(drawn.count == plain.count + 2)
            let trill = try #require(drawn.first { $0.codepoint == 0xE566 })
            let sharp = try #require(drawn.first { $0.codepoint == SMuFLCodepoint.byName("accidentalSharp") })
            #expect(abs(sharp.size - trill.size * 0.6) < 1e-6)
        }

        @Test("a composed kind is its pieces; a color is set around it and reset; an unknown kind emits nothing")
        func composedColoredUnknown() throws {
            let composed = Self.glyphs(Self.commands([ChordOrnament(kind: .upMordent)]))
            #expect(composed.count == Self.glyphs(Self.commands([])).count + 5)
            var red = ChordOrnament(kind: .trill)
            red.elementProperties.color = ScoreColor(red: 255, green: 0, blue: 0, alpha: 255)
            let commands = Self.commands([red])
            let index = try #require(commands.firstIndex { command in
                guard case let .glyph(codepoint, _, _, _, _) = command else { return false }
                return codepoint == 0xE566
            })
            let colors = commands[..<index].filter { if case .setColor = $0 { true } else { false } }
            guard case let .setColor(argb) = colors.last
            else {
                Issue.record("no color before the trill")
                return
            }
            #expect(argb == 0xFFFF_0000)
            #expect(commands[index...].contains(.setColor(argb: LayoutBridge.blackARGB)))
            #expect(Self.commands([ChordOrnament(kind: .unknown(subtype: "ornamentComma"))]) == Self.commands([]))
        }
    }
#endif
