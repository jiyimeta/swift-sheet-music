#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The draw program carries a gradual tempo line with the opcodes it already had: the label's runs, a `setDash` at
    /// MuseScore's 6 / 9 line widths, the line, and the dash reset.
    @Suite("LayoutBridge gradual tempo line")
    struct LayoutBridgeGradualTempoTests {
        private let _installApple = TestSupport.installApple
        private static let mm = LayoutBridge.ptToMMScale

        @Test("the line is dashed at MuseScore's pattern and the label is bold")
        func dashedLineAndBoldLabel() throws {
            let sp = 5.0
            let metrics = StaffMetrics(staffSize: CGFloat(sp) * 4)
            let label = try #require(LayoutRichText.gradualTempoChangeLabel("rit.", metrics: metrics))
            var out: [DrawCommand] = []
            LayoutBridge.encodeSpanner(
                kind: .gradualTempoChange, fromX: 20, fromY: 50, toX: 220, toY: 50,
                continuesLeft: false, continuesRight: false, text: "rit.", sp: sp, glyphSize: sp * 4,
                richText: label, into: &out,
            )
            let dash = out.compactMap { command -> (Double, Double)? in
                if case let .setDash(on, off) = command, on > 0 { return (on, off) }
                return nil
            }
            try #require(dash.count == 1)
            #expect(abs(dash[0].0 - sp * 0.9 * Self.mm) < 1e-9)
            #expect(abs(dash[0].1 - sp * 1.35 * Self.mm) < 1e-9)
            #expect(out.contains { if case let .text(text, _, _, _, _) = $0 { text == "rit." } else { false } })
            #expect(out.contains(.setTextStyle(flags: DrawCommand.TextStyleFlag.bold)))
            #expect(out.last == .setDash(onMM: 0, offMM: 0))
        }
    }
#endif
