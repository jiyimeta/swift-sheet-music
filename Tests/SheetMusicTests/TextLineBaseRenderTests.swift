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
    /// each stroke as a flat-capped path.
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
            #expect(abs(box.minX - (parts.strokes.first?.first?.x ?? .nan)) < 0.01)
            #expect(abs(box.maxX - Self.to.x) < 0.01)
            // One FILLED shape layer (`richTextLayer` returns a `CAShapeLayer` with no stroke) for the Ped glyph, none
            // at the right end.
            let filled = shapes.filter { $0.strokeColor == nil && $0.fillColor != nil }
            #expect(filled.count == 1)
        }

        @available(macOS 15.0, *)
        @Test("a let-ring line is dashed at MuseScore's 5 and 5 line widths")
        func letRingDashes() throws {
            let (element, _, _) = Self.segment(kind: .letRing, xml: "let ring")
            let line = try #require(Self.shapeLayers(element).first { $0.lineDashPattern != nil })
            let lw = Self.metrics.sp * 0.11
            let dashes = line.lineDashPattern?.map(\.doubleValue) ?? []
            #expect(dashes.count == 2)
            #expect(dashes.filter { abs($0 - Double(5 * lw)) > 1e-6 }.isEmpty)
        }

        @available(macOS 15.0, *)
        @Test("hooked pedal: the end hook is part of the stroked path")
        func hookedPedal() throws {
            let (element, _, _) = Self.segment(kind: .pedal, xml: nil) {
                $0.endHook = .hook90
                $0.beginHook = .hook90
            }
            let line = try #require(Self.shapeLayers(element).first)
            let box = try #require(line.path?.boundingBoxOfPath)
            #expect(box.height >= 1.2 * Self.metrics.sp - 0.01)
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
            #expect(starSpan.upperBound >= 205) // the rosette sits at the end
            // The asterisk pedal draws no line: the dark pixels in its middle columns are only the label's, if any.
            let middle = 120
            #expect(starRows.filter { $0[middle] < 200 }.isEmpty)
            #expect(!plainRows.filter { $0[middle] < 200 }.isEmpty)
        }
    }
#endif
