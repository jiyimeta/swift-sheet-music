#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The draw program carries the text-line family with the opcodes it already had: the labels' runs, the strokes of
    /// `SpannerGeometry.textLineBase`, and `setDash` brackets for a line that is not solid.
    @Suite("LayoutBridge text lines")
    struct LayoutBridgeTextLineBaseTests {
        private let _installApple = TestSupport.installApple
        private static let mm = LayoutBridge.ptToMMScale
        private static let sp = 5.0
        private static var metrics: StaffMetrics {
            StaffMetrics(staffSize: CGFloat(sp) * 4)
        }

        private static func encode(
            _ kind: LayoutElement.SpannerKind, xml: String?,
            _ configure: (inout LayoutLineDetail) -> Void = { _ in },
        ) -> [DrawCommand] {
            let label = xml.map { LayoutRichText(RichText(xmlText: $0), style: .staffText, metrics: metrics) }
            var detail = LayoutEngine.lineDetailDefaults(
                kind: kind, lineProperties: nil, endText: nil, placedBelow: true, metrics: metrics,
            ) ?? LayoutLineDetail()
            configure(&detail)
            var out: [DrawCommand] = []
            LayoutBridge.encodeSpanner(
                kind: kind, fromX: 20, fromY: 50, toX: 220, toY: 50, continuesLeft: false, continuesRight: false,
                text: "", sp: sp, glyphSize: sp * 4, richText: label, lineDetail: detail, into: &out,
            )
            return out
        }

        private static func strokes(_ out: [DrawCommand]) -> Int {
            out.filter { if case .stroke = $0 { true } else { false } }.count
        }

        @Test("a pedal is a Ped glyph run and a solid line: no second glyph at the far end, no jump-sized text")
        func pedal() {
            let out = Self.encode(.pedal, xml: "<sym>keyboardPedalPed</sym>")
            let glyphs = out.compactMap { command -> UInt32? in
                if case let .glyph(codepoint, _, _, _, _) = command { return codepoint }
                return nil
            }
            #expect(glyphs == [0xE650])
            #expect(Self.strokes(out) == 1)
            #expect(!out.contains { if case .setDash = $0 { true } else { false } })
        }

        @Test("a let-ring label is in the same face and size as the Apple render, not the jump-sized label")
        func labelStyle() {
            let out = Self.encode(.letRing, xml: "let ring")
            let sizes = out.compactMap { command -> Double? in
                if case let .text(_, _, _, size, _) = command { return size }
                return nil
            }
            let expected = LayoutRichText(RichText(xmlText: "let ring"), style: .staffText, metrics: Self.metrics)
            let want = Double(expected.lines.first?.runs.first?.font.pointSize ?? .nan)
            #expect(sizes.count == 1)
            #expect(abs((sizes.first ?? .nan) - want * Self.mm) < 1e-9)
        }

        @Test("dashed kinds bracket the stroke with setDash at the style's pattern and reset it")
        func dashes() {
            let out = Self.encode(.letRing, xml: nil)
            let lw = Self.sp * 0.11
            let dash = out.compactMap { command -> (Double, Double)? in
                if case let .setDash(on, off) = command, on > 0 { return (on, off) }
                return nil
            }
            #expect(dash.count == 1)
            #expect(abs((dash.first?.0 ?? 0) - 5 * lw * Self.mm) < 1e-9)
            // The solid T hook is drawn after the dashed main line, so the reset is the last `setDash`, not the last
            // command.
            let dashCommands = out.filter { if case .setDash = $0 { true } else { false } }
            #expect(dashCommands.last == .setDash(onMM: 0, offMM: 0))
            #expect(dashCommands.count == 2)
        }

        @Test("a 90T hook on a dashed line is a solid stroke: no setDash between its start and its stroke")
        func teeHookSolid() {
            let out = Self.encode(.letRing, xml: nil) { $0.endHook = .hook90T }
            let firstStroke = out.firstIndex { if case .stroke = $0 { true } else { false } } ?? 0
            let resetAfterMain = out.firstIndex(of: .setDash(onMM: 0, offMM: 0)) ?? -1
            #expect(resetAfterMain > firstStroke)
            let tail = out[(resetAfterMain + 1)...]
            #expect(Self.strokes(Array(tail)) == 1)
            #expect(!tail.contains { if case .setDash = $0 { true } else { false } })
        }

        @Test("a dotted line is square dots, setDash on == off == the line width: the program has no round cap")
        func dotted() {
            let out = Self.encode(.pedal, xml: nil) { $0.lineType = .dotted }
            let lineWidthMM = Self.sp * 0.11 * Self.mm
            let dashes = out.compactMap { command -> (Double, Double)? in
                if case let .setDash(on, off) = command, on > 0 { return (on, off) }
                return nil
            }
            #expect(dashes.count == 1)
            #expect(abs((dashes.first?.0 ?? .nan) - lineWidthMM) < 1e-9)
            #expect(abs((dashes.first?.1 ?? .nan) - lineWidthMM) < 1e-9)
            #expect(out.contains(.setDash(onMM: 0, offMM: 0)))
        }

        @Test("an end hook is a second point of the polyline; a 90T hook is a second stroke")
        func hooks() {
            let hooked = Self.encode(.pedal, xml: nil) { $0.endHook = .hook90 }
            #expect(hooked.filter { if case .lineTo = $0 { true } else { false } }.count == 2)
            let tee = Self.encode(.letRing, xml: nil) { $0.endHook = .hook90T }
            #expect(Self.strokes(tee) == 2)
        }

        /// The strings of every `.text` command a volta segment encodes.
        private static func voltaTexts(richXML: String?) -> [String] {
            let rich = richXML.map { LayoutRichText(RichText(xmlText: $0), style: .staffText, metrics: metrics) }
            var out: [DrawCommand] = []
            LayoutBridge.encodeSpanner(
                kind: .volta(endings: [1]), fromX: 20, fromY: 50, toX: 220, toY: 50,
                continuesLeft: false, continuesRight: false,
                text: "1.", sp: sp, glyphSize: sp * 4, richText: rich, lineDetail: nil, into: &out,
            )
            return out.compactMap { command -> String? in
                if case let .text(text, _, _, _, _) = command { return text }
                return nil
            }
        }

        @Test("a volta with authored text draws only that text; one without draws its endings label")
        func voltaDrawsOneLabel() {
            #expect(Self.voltaTexts(richXML: "Last time") == ["Last time"])
            #expect(Self.voltaTexts(richXML: nil) == ["1."])
        }

        @Test("an invisible line draws its labels and no stroke")
        func invisible() {
            let out = Self.encode(.pedal, xml: "<sym>keyboardPedalPed</sym>") {
                $0.lineVisible = false
                $0.endHook = .rosette
            }
            #expect(Self.strokes(out) == 0)
            #expect(out.contains { if case .glyph = $0 { true } else { false } })
        }
    }
#endif
