#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// The draw program carries a tempo marking as its runs with the opcodes it already had — the metronome glyph a
    /// SMuFL `.glyph`, the words and number `.text` — measured with the portable table provider Android and the web
    /// read.
    @Suite("LayoutBridge tempo text")
    struct LayoutBridgeTempoTests {
        /// Registers Edwin, which `LayoutEngine.layout` asserts a real provider for in DEBUG.
        private let _installApple = TestSupport.installApple
        private static let mm = LayoutBridge.ptToMMScale
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        private static func tableProvider() throws -> any FontMetricsProvider {
            let url = try #require(TestResources.url(forResource: "sheet-music", withExtension: "smft"))
            return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: url)))
        }

        private static func render(_ score: Score) throws -> (document: LayoutDocument, commands: [DrawCommand]) {
            try FontMetrics.$scopedProvider.withValue(tableProvider()) {
                let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
                return (document, LayoutBridge.buildCommands(layout: document))
            }
        }

        private static func score(_ tempo: Tempo) -> Score {
            var score = EditingFixtures.fourQuarterRests()
            score.systemMeasures = [SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(tempo), originalStaff: staff),
            ])]
            return score
        }

        /// The first tempo's runs and its origin in document coordinates (system and measure origins added).
        private static func tempo(in document: LayoutDocument) -> (origin: CGPoint, rich: LayoutRichText)? {
            for system in document.systems {
                for measure in system.measures {
                    for element in measure.elements {
                        guard case let .textMark(.tempo, _, origin, rich?) = element else { continue }
                        let x = measure.origin.x + system.origin.x + origin.x
                        let y = measure.origin.y + system.origin.y + origin.y
                        return (CGPoint(x: x, y: y), rich)
                    }
                }
            }
            return nil
        }

        /// Whether every run of `rich` placed at `origin` is drawn at its position: text as `.text`, a symbol as
        /// `.glyph`.
        private static func drawsAllRuns(
            of rich: LayoutRichText, at origin: CGPoint, in commands: [DrawCommand],
        ) -> Bool {
            rich.positionedRuns(at: origin, anchor: LayoutRichText.anchor(for: .tempo)).allSatisfy { run in
                let x = Double(run.baseline.x) * mm
                let y = Double(run.baseline.y) * mm
                return commands.contains { command in
                    switch (command, run.content) {
                    case let (.text(drawn, cx, cy, _, _), .text(string)):
                        drawn == string && abs(cx - x) < 0.001 && abs(cy - y) < 0.001
                    case let (.glyph(drawn, cx, cy, _, _), .symbol(codepoint)):
                        drawn == codepoint && abs(cx - x) < 0.001 && abs(cy - y) < 0.001
                    default:
                        false
                    }
                }
            }
        }

        private static func drawsMetronomeGlyph(_ commands: [DrawCommand]) -> Bool {
            commands.contains { if case .glyph(0xECA5, _, _, _, _) = $0 { true } else { false } }
        }

        @Test("a derived marking draws the metronome glyph and the number where layout placed them")
        func derivedMarking() throws {
            let rendered = try Self.render(Self.score(Tempo(beatsPerSecond: 2)))
            let found = try #require(Self.tempo(in: rendered.document))
            #expect(Self.drawsAllRuns(of: found.rich, at: found.origin, in: rendered.commands))
            #expect(Self.drawsMetronomeGlyph(rendered.commands))
        }

        @Test("a MuseScore 3 marking draws its ScoreText character as the glyph")
        func legacyMarking() throws {
            let rendered = try Self.render(MSCXParser.parse(MSCXFixtureLoader.mscxData("testVoltaTemp")))
            let found = try #require(Self.tempo(in: rendered.document))
            #expect(Self.drawsAllRuns(of: found.rich, at: found.origin, in: rendered.commands))
            #expect(Self.drawsMetronomeGlyph(rendered.commands))
        }
    }
#endif
