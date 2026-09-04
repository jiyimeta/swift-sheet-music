#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicLayout
    import Testing

    struct LayoutBridgeBarLineTests {
        private let _installApple = TestSupport.installApple

        private static let ptToMM = 25.4 / 72.0
        private static let sp = 5.0
        private static let barCenterXPt = 50.0
        private static let barCenterYPt = 30.0
        private static let repeatDotCodepoint: UInt32 = 0xE044

        private struct Stroke {
            let commandIndex: Int
            let x: Double
            let width: Double
        }

        private struct Glyph {
            let commandIndex: Int
            let codepoint: UInt32
            let x: Double
            let y: Double
            let size: Double
            let fontId: DrawProgram.FontID
        }

        private static func commands(subtype: String?) -> [DrawCommand] {
            let metrics = StaffMetrics(staffSize: 20)
            let measure = LayoutMeasure(
                measureIndex: 0,
                origin: CGPoint(x: 7, y: 8),
                width: 80,
                elements: [.barLine(
                    subtype: subtype,
                    origin: CGPoint(x: 40, y: 20),
                    halfHeight: 10,
                )],
            )
            let system = LayoutSystem(
                origin: CGPoint(x: 3, y: 2),
                size: CGSize(width: 100, height: 60),
                measures: [measure],
                staffOrigins: [],
                partLabels: [],
                spanners: [],
                sp: metrics.sp,
            )
            let document = LayoutDocument(
                size: system.size,
                systems: [system],
                metrics: metrics,
            )
            return LayoutBridge.buildCommands(layout: document)
        }

        private static func strokes(in commands: [DrawCommand]) -> [Stroke] {
            commands.indices.compactMap { index in
                guard index >= 2,
                      case let .moveTo(moveX, _) = commands[index - 2],
                      case let .lineTo(lineX, _) = commands[index - 1],
                      case let .stroke(width) = commands[index],
                      moveX == lineX
                else { return nil }
                return Stroke(commandIndex: index, x: moveX, width: width)
            }
        }

        private static func glyphs(in commands: [DrawCommand]) -> [Glyph] {
            commands.indices.compactMap { index in
                guard case let .glyph(
                    codepoint, x, y, size, fontId,
                ) = commands[index]
                else { return nil }
                return Glyph(
                    commandIndex: index,
                    codepoint: codepoint,
                    x: x,
                    y: y,
                    size: size,
                    fontId: fontId,
                )
            }
        }

        private static func expectedX(dxSp: Double) -> Double {
            (barCenterXPt + dxSp * sp) * ptToMM
        }

        private static func expectedWidth(_ widthSp: Double) -> Double {
            widthSp * sp * ptToMM
        }

        private static func approximatelyEqual(
            _ lhs: Double, _ rhs: Double,
        ) -> Bool {
            abs(lhs - rhs) < 0.0001
        }

        private static func matches(
            _ strokes: [Stroke], _ expected: [(dxSp: Double, widthSp: Double)],
        ) -> Bool {
            guard strokes.count == expected.count else { return false }
            return zip(strokes, expected).allSatisfy { stroke, expected in
                approximatelyEqual(stroke.x, expectedX(dxSp: expected.dxSp))
                    && approximatelyEqual(
                        stroke.width, expectedWidth(expected.widthSp),
                    )
            }
        }

        private static func repeatDotCenterX(_ glyph: Glyph) -> Double? {
            guard let scalar = UnicodeScalar(repeatDotCodepoint) else {
                return nil
            }
            let font = LayoutFont(
                face: SMuFLFamily.bravura,
                pointSize: CGFloat(sp * 3),
            )
            let advance = Double(FontMetrics.provider.typographicWidth(
                text: String(scalar), font: font,
            ))
            return glyph.x + advance / 2 * ptToMM
        }

        @Test("double barline emits two offset thin strokes")
        func doubleBarLine() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let commands = Self.commands(subtype: "double")
            let strokes = Self.strokes(in: commands)
            #expect(commands.count == 6)
            #expect(Self.matches(strokes, [(-0.3, 0.15), (0.3, 0.15)]))
            #expect(Self.glyphs(in: commands).isEmpty)
        }

        @Test(
            "end barlines emit thin then right-offset thick strokes",
            arguments: ["end", "final"],
        )
        func endBarLine(subtype: String) {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let commands = Self.commands(subtype: subtype)
            let strokes = Self.strokes(in: commands)
            #expect(commands.count == 6)
            #expect(Self.matches(strokes, [(0, 0.15), (0.4, 0.4)]))
            #expect(Self.glyphs(in: commands).isEmpty)
        }

        @Test(
            "repeat barlines emit ordered stroke pairs and two dots",
            arguments: ["end-repeat", "start-repeat"],
        )
        func repeatBarLine(subtype: String) throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let commands = Self.commands(subtype: subtype)
            let strokes = Self.strokes(in: commands)
            let glyphs = Self.glyphs(in: commands)
            #expect(commands.count == 8)
            let expectedStrokes: [(dxSp: Double, widthSp: Double)]
            let expectedDotDxSp: Double
            if subtype == "end-repeat" {
                expectedStrokes = [(0, 0.15), (0.3, 0.4)]
                expectedDotDxSp = -0.6
                let lastGlyph = try #require(glyphs.last)
                let firstStroke = try #require(strokes.first)
                #expect(lastGlyph.commandIndex < firstStroke.commandIndex)
            } else {
                expectedStrokes = [(0, 0.4), (0.3, 0.15)]
                expectedDotDxSp = 0.6
                let lastStroke = try #require(strokes.last)
                let firstGlyph = try #require(glyphs.first)
                #expect(lastStroke.commandIndex < firstGlyph.commandIndex)
            }
            #expect(Self.matches(strokes, expectedStrokes))
            #expect(glyphs.count == 2)
            for glyph in glyphs {
                #expect(glyph.codepoint == Self.repeatDotCodepoint)
                #expect(glyph.fontId == .smufl)
                #expect(Self.approximatelyEqual(
                    glyph.size, Self.sp * 3 * Self.ptToMM,
                ))
                let centerX = try #require(Self.repeatDotCenterX(glyph))
                #expect(Self.approximatelyEqual(
                    centerX, Self.expectedX(dxSp: expectedDotDxSp),
                ))
            }
            let expectedYs = [-0.5, 0.5].map {
                (Self.barCenterYPt + $0 * Self.sp) * Self.ptToMM
            }
            #expect(zip(glyphs.map(\.y), expectedYs).allSatisfy {
                Self.approximatelyEqual($0, $1)
            })
        }

        @Test("plain barline emits one centered thin stroke")
        func plainBarLine() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let commands = Self.commands(subtype: nil)
            let strokes = Self.strokes(in: commands)
            #expect(commands.count == 3)
            #expect(Self.matches(strokes, [(0, 0.15)]))
            #expect(Self.glyphs(in: commands).isEmpty)
        }
    }
#endif
