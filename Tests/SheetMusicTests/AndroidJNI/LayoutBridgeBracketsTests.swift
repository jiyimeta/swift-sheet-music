#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The Android draw-command bridge must engrave the system-start
    /// decorations the Apple renderer draws: the vertical system barline
    /// joining all staves at the left edge, plus the per-`BracketItem`
    /// braces / brackets. Before this fix `buildCommands` walked staff
    /// lines, measure elements, and spanners only — `system.brackets` and
    /// the system barline were silently dropped, so Android showed none of
    /// them.
    struct LayoutBridgeBracketsTests {
        private let _installApple = TestSupport.installApple

        private static let ptToMM = 25.4 / 72.0

        private static func twoStaffScore(
            bracket: BracketItem?,
        ) -> Score {
            let measure = Measure(
                voices: [Voice(elements: [.rest(duration: .measure)])],
            )
            return Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [
                        Staff(
                            brackets: bracket.map { [$0] } ?? [],
                            measures: [measure],
                        ),
                        Staff(measures: [measure]),
                    ],
                )],
                systemMeasures: [SystemMeasure()],
            )
        }

        private static func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 1200,
            )
        }

        private static func approxEq(
            _ a: Double, _ b: Double, eps: Double = 0.05,
        ) -> Bool {
            abs(a - b) < eps
        }

        @Test("a multi-staff system emits the vertical system barline")
        func emitsSystemBarline() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.layout(Self.twoStaffScore(bracket: nil))
            let commands = LayoutBridge.buildCommands(layout: doc)

            let system = doc.systems[0]
            let first = try #require(system.staffOrigins.first)
            let last = try #require(system.staffOrigins.last)
            let sysX = Double(system.origin.x)
            let sysY = Double(system.origin.y)
            let expX = (sysX + Double(first.x)) * Self.ptToMM
            let expTop = (sysY + Double(first.y)) * Self.ptToMM
            let expBottom = (
                sysY + Double(last.y)
                    + Double(doc.metrics.staffHeight),
            ) * Self.ptToMM

            // A vertical moveTo→lineTo at the staff-left X spanning from the
            // top of the first staff to the bottom of the last staff.
            let hasBarline = (0 ..< commands.count - 1).contains { i in
                guard case let .moveTo(mx, my) = commands[i],
                      case let .lineTo(lx, ly) = commands[i + 1]
                else { return false }
                return Self.approxEq(mx, expX) && Self.approxEq(lx, expX)
                    && Self.approxEq(my, expTop) && Self.approxEq(ly, expBottom)
            }
            #expect(hasBarline)
        }

        @Test("a normal bracket emits its top + bottom cap glyphs")
        func normalBracketEmitsCapGlyphs() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.layout(Self.twoStaffScore(
                bracket: BracketItem(type: .normal, span: 2),
            ))
            let commands = LayoutBridge.buildCommands(layout: doc)

            func hasGlyph(_ cp: UInt32) -> Bool {
                commands.contains { cmd in
                    if case let .glyph(codepoint, _, _, _, _) = cmd {
                        return codepoint == cp
                    }
                    return false
                }
            }
            #expect(hasGlyph(SMuFLCodepoint.bracketTop))
            #expect(hasGlyph(SMuFLCodepoint.bracketBottom))
        }
    }
#endif
