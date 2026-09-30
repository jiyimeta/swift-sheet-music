#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("Bridge text ink anchors")
    @MainActor struct TextInkBridgeTests {
        private let _installApple = TestSupport.installApple

        @Test(arguments: ["A", "B\nframe", "A\ng", "A\n\ng"], [TextFrameType.none, .rectangle, .circle])
        func rehearsalCommandsMatchTextAndFrameInk(text: String, frame: TextFrameType) throws {
            guard #available(macOS 15.0, *) else { return }
            let element = LayoutElement.rehearsalMark(
                text: text,
                origin: ElementHitFixtures.origin,
                frame: frame,
                color: nil,
                measureIndex: 0,
            )
            let doc = ElementHitFixtures.document([element])
            let actual = try #require(ScoreHitTester(document: doc).textHitRect(for: .rehearsalMark(measureIndex: 0)))
            let commands = LayoutBridge.buildCommands(layout: doc)
            var expected = try #require(Self.textBounds(commands))
            if let frame = Self.strokeBounds(commands) { expected = expected.union(frame) }
            #expect(abs(actual.minX - expected.minX) < 0.001)
            #expect(abs(actual.minY - expected.minY) < 0.001)
            #expect(abs(actual.maxX - expected.maxX) < 0.001)
            #expect(abs(actual.maxY - expected.maxY) < 0.001)
        }

        @Test func harmonyCommandsRespectRunOffsetsAndFontSizeOverrides() throws {
            guard #available(macOS 15.0, *) else { return }
            let harmony = Harmony(name: "C#7", properties: TextProperties(size: 21, style: [.bold]))
            let runs = HarmonyRendering.runs(for: harmony, metrics: ElementHitFixtures.metrics)
            let layout = LayoutHarmony(
                harmony: harmony,
                anchorX: 80,
                y: 80,
                runs: runs,
                width: HarmonyRendering.width(of: runs),
                anchor: ElementHitFixtures.anchor,
            )
            let doc = ElementHitFixtures.document([.harmony(layout)])
            let actual = try #require(ScoreHitTester(document: doc)
                .textHitRect(for: .harmony(anchor: ElementHitFixtures.anchor)))
            let commands = LayoutBridge.buildCommands(layout: doc)
            let expected = try #require(Self.textBounds(commands))
            #expect(abs(actual.minX - expected.minX) < 0.001)
            #expect(abs(actual.minY - expected.minY) < 0.001)
            #expect(abs(actual.maxX - expected.maxX) < 0.001)
            #expect(abs(actual.maxY - expected.maxY) < 0.001)
            let sizes = commands.compactMap { command -> Double? in
                if case let .text(_, _, _, size, _) = command { size * 72 / 25.4 } else { nil }
            }
            #expect(!sizes.isEmpty)
            #expect(sizes.allSatisfy { abs($0 - 42) < 0.001 })
        }

        @Test(arguments: ["A", "g", "A\ng", "A\n\ng", " A "])
        func textCommandsPaintInsideTheHighlight(text: String) throws {
            guard #available(macOS 15.0, *) else { return }
            let element = LayoutElement.staffText(
                text: text,
                origin: ElementHitFixtures.origin,
                color: nil,
                style: .staffText,
                anchor: ElementHitFixtures.anchor,
            )
            let doc = ElementHitFixtures.document([element])
            let got = try #require(ScoreHitTester(document: doc).textHitRect(
                for: .staffText(anchor: ElementHitFixtures.anchor, style: .staffText),
            ))
            let painted = try #require(Self.textBounds(LayoutBridge.buildCommands(layout: doc)))
            #expect(abs(got.minX - painted.minX) < 0.001)
            #expect(abs(got.minY - painted.minY) < 0.001)
            #expect(abs(got.maxX - painted.maxX) < 0.001)
            #expect(abs(got.maxY - painted.maxY) < 0.001)
        }

        /// A notation label's position is anchored against the ink the Apple provider measured — the system face,
        /// semibold — so the command has to name that face, or a reader draws Edwin at an x resolved for SF and a
        /// right- or center-anchored label misses its anchor. Drawn back in the face its id and style bits name, the
        /// command paints exactly the ink rect the layout reports.
        @Test(arguments: 0 ... 2)
        func notationLabelsPaintTheInkTheLayoutMeasured(kind: Int) throws {
            guard #available(macOS 15.0, *) else { return }
            let origin = ElementHitFixtures.origin
            let element: LayoutElement = switch kind {
            case 0: .measureNumber(text: "17", origin: origin)
            case 1: .staffName(text: "Violin", origin: origin)
            default: .jump(text: "D.S. al Fine", origin: origin)
            }
            let doc = ElementHitFixtures.document([element])
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let local = try #require(TextInkGeometry.rects(for: element, metrics: doc.metrics)?.first)
            let measured = local.offsetBy(
                dx: system.origin.x + measure.origin.x, dy: system.origin.y + measure.origin.y,
            )
            let commands = LayoutBridge.buildCommands(layout: doc)
            #expect(commands.contains {
                if case let .text(_, _, _, _, fontID) = $0 { fontID == .system } else { false }
            })
            let painted = try #require(Self.textBounds(commands))
            #expect(abs(measured.minX - painted.minX) < 0.001)
            #expect(abs(measured.minY - painted.minY) < 0.001)
            #expect(abs(measured.maxX - painted.maxX) < 0.001)
            #expect(abs(measured.maxY - painted.maxY) < 0.001)
        }

        /// Decode the actual emitted baseline commands, then independently typeset their payloads.
        static func textBounds(_ commands: [DrawCommand]) -> CGRect? {
            var result: CGRect?
            var flags: UInt8 = 0
            let scale = 72.0 / 25.4
            for command in commands {
                if case let .setTextStyle(value) = command { flags = value }
                let text: String
                let x: Double
                let y: Double
                let size: Double
                let fontID: DrawProgram.FontID
                switch command {
                case let .text(value, px, py, pointSize, face):
                    (text, x, y, size, fontID) = (value, px, py, pointSize, face)
                case let .glyph(codepoint, px, py, pointSize, face):
                    guard let scalar = Unicode.Scalar(codepoint) else { continue }
                    (text, x, y, size, fontID) = (String(scalar), px, py, pointSize, face)
                default: continue
                }
                let font = TextInkOracle.font(fontID: fontID, size: size * scale, flags: flags)
                guard let ink = TextInkOracle.path(text, font: font)?.boundingBoxOfPath else { continue }
                let rect = CGRect(
                    x: x * scale + ink.minX,
                    y: y * scale - ink.maxY,
                    width: ink.width,
                    height: ink.height,
                )
                result = result.map { $0.union(rect) } ?? rect
            }
            return result
        }

        /// The painted bounds of every path: a stroked one widened by its width, a filled one (`fillPath`) its own
        /// points. Each terminator ends its path, as it does in every reader.
        private static func strokeBounds(_ commands: [DrawCommand]) -> CGRect? {
            var path = CGMutablePath()
            let scale = 72.0 / 25.4
            var result: CGRect?
            for command in commands {
                switch command {
                case let .moveTo(x, y): path.move(to: CGPoint(x: x * scale, y: y * scale))
                case let .lineTo(x, y): path.addLine(to: CGPoint(x: x * scale, y: y * scale))
                case let .cubicTo(cx1, cy1, cx2, cy2, x, y):
                    path.addCurve(
                        to: CGPoint(x: x * scale, y: y * scale),
                        control1: CGPoint(x: cx1 * scale, y: cy1 * scale),
                        control2: CGPoint(x: cx2 * scale, y: cy2 * scale),
                    )
                case let .stroke(width):
                    let bounds = path.copy(
                        strokingWithWidth: width * scale,
                        lineCap: .butt,
                        lineJoin: .miter,
                        miterLimit: 10,
                    ).boundingBoxOfPath
                    result = result.map { $0.union(bounds) } ?? bounds
                    path = CGMutablePath()
                case .fillPath:
                    let bounds = path.boundingBoxOfPath
                    result = result.map { $0.union(bounds) } ?? bounds
                    path = CGMutablePath()
                default: break
                }
            }
            return result
        }
    }
#endif
