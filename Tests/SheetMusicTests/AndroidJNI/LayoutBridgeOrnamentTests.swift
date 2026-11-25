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

        private static let anchor = VoiceElementID(
            staff: AnnotationFixtures.address, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
        private static let tint: UInt32 = 0xFFAB_CDEF

        private static func commands(
            _ ornaments: [ChordOrnament], selecting items: Set<ScoreItemID>,
        ) -> [DrawCommand] {
            LayoutBridge.buildCommands(
                layout: AnnotationFixtures.layout(AnnotationFixtures.score([
                    .chord(Chord(
                        duration: .half, notes: ChordNotes([Note(pitch: 72, tpc: 14)]), ornaments: ornaments,
                    )),
                ])),
                tint: (argb: tint, ids: items),
            )
        }

        /// The color each glyph is painted in, in order.
        private static func colors(_ commands: [DrawCommand]) -> [(codepoint: UInt32, argb: UInt32)] {
            var argb = LayoutBridge.blackARGB
            var result: [(codepoint: UInt32, argb: UInt32)] = []
            for command in commands {
                switch command {
                case let .setColor(color): argb = color
                case let .glyph(codepoint, _, _, _, _): result.append((codepoint, argb))
                default: continue
                }
            }
            return result
        }

        @Test("a selected one is tinted whole, its accidental and its author color included; nothing else is")
        func selectedTint() throws {
            var red = ChordOrnament(kind: .upMordent, accidentalAbove: .sharp)
            red.elementProperties.color = ScoreColor(red: 255, green: 0, blue: 0, alpha: 255)
            let ornaments = [red, ChordOrnament(kind: .trill)]
            let item = ScoreItemID.element(.ornament(anchor: Self.anchor, kind: .upMordent))
            let plain = Self.colors(Self.commands(ornaments))
            let tinted = Self.colors(Self.commands(ornaments, selecting: [item]))
            #expect(tinted.map(\.codepoint) == plain.map(\.codepoint))
            // Five pieces and the sharp, red until selected; the trill, the notehead and the rest of the page as
            // before.
            #expect(plain.count { $0.argb == 0xFFFF_0000 } == 6)
            #expect(tinted.count { $0.argb == Self.tint } == 6)
            #expect(!tinted.contains { $0.argb == 0xFFFF_0000 })
            let trill = try #require(tinted.first { $0.codepoint == 0xE566 })
            #expect(trill.argb == LayoutBridge.blackARGB)
            for (before, after) in zip(plain, tinted) where before.argb != 0xFFFF_0000 {
                #expect(before.argb == after.argb)
            }
            // Another kind on the same chord, and the note itself, are other items.
            for other in [
                ScoreItemID.element(.ornament(anchor: Self.anchor, kind: .turn)),
                .note(NoteID(
                    staff: AnnotationFixtures.address, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
                    noteIndexInChord: 0,
                )),
            ] {
                let untouched = Self.colors(Self.commands(ornaments, selecting: [other]))
                #expect(untouched.count { $0.argb == 0xFFFF_0000 } == 6)
            }
        }
    }
#endif
