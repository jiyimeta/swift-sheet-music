#if os(macOS)
    import CoreGraphics
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    /// Both Apple renderers draw the text-line family from `SpannerGeometry.textLineBase`: the labels' runs filled and
    /// each stroke as a path with its own dash pattern and cap.
    @Suite("Text lines reach the Apple renderers", .serialized)
    @MainActor
    struct TextLineBaseRenderTests {
        private let _installApple = TestSupport.installApple
        private static let metrics = StaffMetrics(staffSize: 20)
        private static let from = CGPoint(x: 20, y: 80)
        private static let to = CGPoint(x: 220, y: 80)

        private static func segment(
            kind: LayoutElement.SpannerKind, xml: String?,
            _ configure: (inout LayoutLineDetail) -> Void = { _ in },
        ) -> (element: LayoutElement, label: LayoutRichText?, detail: LayoutLineDetail) {
            let label = xml.map { LayoutRichText(RichText(xmlText: $0), style: .staffText, metrics: metrics) }
            var detail = LayoutEngine.lineDetailDefaults(
                kind: kind, lineProperties: nil, endText: nil, placedBelow: true, metrics: metrics,
            ) ?? LayoutLineDetail()
            configure(&detail)
            let element = LayoutElement.spannerSegment(
                kind: kind, fromOrigin: from, toOrigin: to, continuesLeft: false, continuesRight: false,
                text: "", anchor: nil, richText: label, lineDetail: detail,
            )
            return (element, label, detail)
        }

        @available(macOS 15.0, *)
        private static func shapeLayers(_ element: LayoutElement) -> [CAShapeLayer] {
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                element, base: .zero, metrics: metrics, height: 400, context: &context, into: parent,
            )
            return (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        }

        @available(macOS 15.0, *)
        @Test("a pedal layer tree is its label and a solid flat-capped line, with no glyph at the far end")
        func pedalLayers() throws {
            let (element, label, detail) = Self.segment(kind: .pedal, xml: "<sym>keyboardPedalPed</sym>")
            let shapes = Self.shapeLayers(element)
            let line = try #require(shapes.first { $0.strokeColor != nil && $0.lineDashPattern == nil })
            #expect(line.lineCap == .butt)
            let parts = SpannerGeometry.textLineBase(
                from: Self.from, to: Self.to, label: label, detail: detail, sp: Self.metrics.sp,
            )
            let box = try #require(line.path?.boundingBoxOfPath)
            #expect(abs(box.minX - (parts.strokes.first?.points.first?.x ?? .nan)) < 0.01)
            #expect(abs(box.maxX - Self.to.x) < 0.01)
            // One FILLED shape layer (`richTextLayer` returns a `CAShapeLayer` with no stroke) for the Ped glyph, none
            // at the right end.
            let filled = shapes.filter { $0.strokeColor == nil && $0.fillColor != nil }
            #expect(filled.count == 1)
        }

        @available(macOS 15.0, *)
        @Test("a let-ring main line is dashed at MuseScore's 5 line widths, its gap stretched to fit")
        func letRingDashes() throws {
            let (element, label, detail) = Self.segment(kind: .letRing, xml: "let ring")
            let line = try #require(Self.shapeLayers(element).first { $0.lineDashPattern != nil })
            let lw = Self.metrics.sp * 0.11
            let dashes = line.lineDashPattern?.map(\.doubleValue) ?? []
            #expect(dashes.count == 2)
            #expect(abs((dashes.first ?? .nan) - Double(5 * lw)) < 1e-6)
            // The layer carries the geometry's per-stroke pattern, not the undistributed style one.
            let parts = SpannerGeometry.textLineBase(
                from: Self.from, to: Self.to, label: label, detail: detail, sp: Self.metrics.sp,
            )
            let expected = parts.strokes.first?.dashPattern.map { Double($0) } ?? []
            #expect(dashes.count == expected.count)
            #expect(zip(dashes, expected).filter { abs($0 - $1) > 1e-6 }.isEmpty)
        }

        @available(macOS 15.0, *)
        @Test("a dotted line's layer has a round cap; the let-ring T hook layer is solid")
        func dottedAndTeeLayers() throws {
            let (dotted, _, _) = Self.segment(kind: .pedal, xml: nil) { $0.lineType = .dotted }
            let dots = try #require(Self.shapeLayers(dotted).first { $0.lineDashPattern != nil })
            #expect(dots.lineCap == .round)
            let (ring, _, _) = Self.segment(kind: .letRing, xml: nil) { $0.endHook = .hook90T }
            let strokes = Self.shapeLayers(ring).filter { $0.strokeColor != nil }
            #expect(strokes.count == 2)
            #expect(strokes.filter { $0.lineDashPattern == nil }.count == 1)
        }

        /// The points of a layer's path, in order.
        @available(macOS 15.0, *)
        private static func points(_ layer: CAShapeLayer) -> [CGPoint] {
            var points: [CGPoint] = []
            layer.path?.applyWithBlock { element in
                if element.pointee.type != .closeSubpath { points.append(element.pointee.points[0]) }
            }
            return points
        }

        @available(macOS 15.0, *)
        @Test("a hook is on the end it was set on: an end hook after the line, a begin hook before it")
        func hookedPedal() throws {
            let (endOnly, _, _) = Self.segment(kind: .pedal, xml: nil) { $0.endHook = .hook90 }
            let end = try Self.points(#require(Self.shapeLayers(endOnly).first))
            try #require(end.count == 3)
            // Line from (20, 80) to (220, 80), then the hook: the line's first two points share a y, the hook point
            // is at the line's end x and a hook's height away.
            #expect(abs(end[0].y - end[1].y) < 0.01)
            #expect(abs(end[2].x - end[1].x) < 0.01 && abs(end[1].x - Self.to.x) < 0.01)
            #expect(abs(abs(end[2].y - end[1].y) - 1.2 * Self.metrics.sp) < 0.01)
            let (beginOnly, _, _) = Self.segment(kind: .pedal, xml: nil) { $0.beginHook = .hook90 }
            let begin = try Self.points(#require(Self.shapeLayers(beginOnly).first))
            try #require(begin.count == 3)
            #expect(abs(begin[1].y - begin[2].y) < 0.01)
            #expect(abs(begin[0].x - begin[1].x) < 0.01 && abs(begin[1].x - Self.from.x) < 0.01)
            #expect(abs(abs(begin[0].y - begin[1].y) - 1.2 * Self.metrics.sp) < 0.01)
        }

        @available(macOS 15.0, *)
        @Test("the Canvas inks the whole span of a pedal and a rosette at the end of an asterisk pedal")
        func canvasPedals() throws {
            let (plain, _, _) = Self.segment(kind: .pedal, xml: "<sym>keyboardPedalPed</sym>")
            let (asterisk, _, _) = Self.segment(kind: .pedal, xml: "<sym>keyboardPedalPed</sym>") {
                $0.lineVisible = false
                $0.endHook = .rosette
                $0.endRichText = LayoutRichText(
                    RichText(xmlText: "<sym>keyboardPedalUp</sym>"), style: .staffText, metrics: Self.metrics,
                )
            }
            let plainRows = try GradualTempoLineRenderTests.renderRows(plain)
            let starRows = try GradualTempoLineRenderTests.renderRows(asterisk)
            func inkedX(_ rows: [[UInt8]]) -> ClosedRange<Int>? {
                let xs = rows.flatMap { row in row.indices.filter { row[$0] < 200 } }
                guard let lo = xs.min(), let hi = xs.max() else { return nil }
                return lo ... hi
            }
            let plainSpan = try #require(inkedX(plainRows))
            let starSpan = try #require(inkedX(starRows))
            #expect(plainSpan.upperBound >= 215) // the line reaches the end
            // The end label's LEFT edge is `to.x` (`tlayout.cpp:5865-5883`), so its ink reaches past the end by
            // about its width; right-aligned at `to.x` it would stop at 220. Half the width tells the two apart.
            let starWidth = LayoutRichText(
                RichText(xmlText: "<sym>keyboardPedalUp</sym>"), style: .staffText, metrics: Self.metrics,
            ).size.width
            #expect(starSpan.upperBound >= Int(Self.to.x + starWidth / 2))
            // The asterisk pedal draws no line: the dark pixels in its middle columns are only the label's, if any.
            let middle = 120
            #expect(starRows.filter { $0[middle] < 200 }.isEmpty)
            #expect(!plainRows.filter { $0[middle] < 200 }.isEmpty)
        }
    }
#endif
