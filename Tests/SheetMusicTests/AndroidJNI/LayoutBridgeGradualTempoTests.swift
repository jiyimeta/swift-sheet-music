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
            // MuseScore's 0.9 sp dash with the gap distributed over the line (`tdraw.cpp:1541-1547`), as the Apple
            // renderers draw it: the geometry's own pattern, in mm.
            let pattern = SpannerGeometry.gradualTempoChange(
                from: CGPoint(x: 20, y: 50), to: CGPoint(x: 220, y: 50), label: label, sp: CGFloat(sp),
            ).dashPattern
            #expect(abs(dash[0].0 - sp * 0.9 * Self.mm) < 1e-9)
            #expect(abs(dash[0].1 - Double(pattern[1]) * Self.mm) < 1e-9)
            #expect(out.contains { if case let .text(text, _, _, _, _) = $0 { text == "rit." } else { false } })
            #expect(out.contains(.setTextStyle(flags: DrawCommand.TextStyleFlag.bold)))
            #expect(out.last == .setDash(onMM: 0, offMM: 0))
            // The line runs half its width above the label's baseline, which is the segment's y (`alignBaseLine`).
            let lineY = out.compactMap { command -> Double? in
                if case let .moveTo(_, y) = command { return y }
                return nil
            }
            try #require(lineY.count == 1)
            #expect(abs(lineY[0] - (50 - sp * 0.15 / 2) * Self.mm) < 1e-9)
        }

        @Test("the end label from the segment's line detail is emitted as text")
        func endLabelIsEmitted() throws {
            let sp = 5.0
            let metrics = StaffMetrics(staffSize: CGFloat(sp) * 4)
            let label = try #require(LayoutRichText.gradualTempoChangeLabel("rit.", metrics: metrics))
            let end = try #require(LayoutRichText.gradualTempoChangeLabel("a tempo", metrics: metrics))
            var out: [DrawCommand] = []
            LayoutBridge.encodeSpanner(
                kind: .gradualTempoChange, fromX: 20, fromY: 50, toX: 220, toY: 50,
                continuesLeft: false, continuesRight: false, text: "rit.", sp: sp, glyphSize: sp * 4,
                richText: label, lineDetail: LayoutLineDetail(endRichText: end), into: &out,
            )
            #expect(out.contains { if case let .text(text, _, _, _, _) = $0 { text == "a tempo" } else { false } })
            #expect(out.contains { if case let .text(text, _, _, _, _) = $0 { text == "rit." } else { false } })
        }
    }
#endif
