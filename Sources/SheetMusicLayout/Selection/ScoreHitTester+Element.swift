#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

@available(macOS 15.0, *)
extension ScoreHitTester {
    /// Tests addressable elements in the order defined by `ScoreHitTarget`'s priority ladder.
    func hitElement(at point: CGPoint) -> ScoreHitTarget? {
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                )
                for elements in [measure.elements, measure.markers, measure.jumps, measure.invisibleElements] {
                    if let target = hitElement(elements: elements, base: base, point: point) {
                        return target
                    }
                }
            }
            for elements in [system.spanners, system.invisibleSpanners] {
                if let target = hitElement(elements: elements, base: system.origin, point: point) {
                    return target
                }
            }
        }
        return nil
    }

    /// First matching ink wins in emission order. Navigation marks currently share origins;
    /// overlapping ink therefore selects the first mark until engraving separates those marks.
    private func hitElement(elements: [LayoutElement], base: CGPoint, point: CGPoint) -> ScoreHitTarget? {
        for element in elements {
            guard let id = element.elementID else { continue }
            if let contains = arcContains(element, point: CGPoint(x: point.x - base.x, y: point.y - base.y)) {
                if contains { return ScoreHitTarget(elementID: id) }
                continue
            }
            let padding = document.metrics.sp * hitTolerance(for: element)
            for rect in hitRects(element) where rect
                .offsetBy(dx: base.x, dy: base.y)
                .insetBy(dx: -padding, dy: -padding).contains(point)
            {
                return ScoreHitTarget(elementID: id)
            }
        }
        return nil
    }

    /// What a click has to land in to mean `element` — which is NOT always the ink it is drawn with.
    ///
    /// **A signature is one thing, so it is one rectangle.** A four-sharp key signature draws four separate
    /// glyphs on four different staff lines, and testing those separately left the gaps between them dead: the
    /// run reads as one mark and is engraved as one column, but a click aimed at the middle of it fell straight
    /// through. Their union is what the eye is aiming at. The same holds for a meter, whose two digits sit one
    /// above the other with a gap between the rows.
    ///
    /// **Everything else keeps its ink separate**, and that is not an oversight: a spanner clipped across a
    /// system break contributes one rectangle per segment, and unioning those would claim the whole page between
    /// them. `elementHitRect(for:)` still answers the union for every kind, because a HIGHLIGHT box around a
    /// selection is a different question from what a click may land in.
    private func hitRects(_ element: LayoutElement) -> [CGRect] {
        let rects = elementRects(element)
        switch element {
        case .keySignature, .timeSignature:
            guard let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else { return [] }
            return [union]
        default:
            return rects
        }
    }

    /// How far outside its own ink a click may land and still mean `element`, in staff spaces.
    ///
    /// Engraved marks are small, and several of them are SMALL ON PURPOSE — a barline is a hairline, a key
    /// signature's accidentals are thinner than a notehead. Testing their ink alone made them targets a pointer
    /// had to be placed on exactly, which reads as the app ignoring the click (user report, 2026-09-12). Every
    /// kind therefore gets the same half staff space of reach that text already had, measured in `sp` so it
    /// tracks the engraving rather than the zoom.
    ///
    /// It stays SMALL deliberately. These targets sit in a dense row — a clef, a key signature and a meter
    /// inside one header column — so reach taken by one is reach taken from its neighbour, and the ladder's
    /// first-match rule would hand a generous padding the leftmost of them every time.
    private func hitTolerance(for element: LayoutElement) -> CGFloat {
        navigationUsesText(element) ? Self.textHitTolerance : Self.elementHitTolerance
    }

    /// Document-space highlight box for an engraved element, without hit padding. Returns nil for a
    /// missing identity or missing geometry. Repeated identities, including clipped spanner segments,
    /// contribute their union; the hit test checks each component separately, never the gaps in that union.
    ///
    /// Skyline shapes are collision approximations; clicks and highlights need ink bounds without padding.
    /// `elementRects` documents which kinds measure ink and which still use skyline approximations.
    /// Barlines and signatures measure ink independently of their skyline reservations.
    /// Pedals share the same painted glyph bounds with the skyline.
    public func elementHitRect(for target: ScoreHitTarget) -> CGRect? {
        let rects = elementHitRects(for: target)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The same geometry, ONE RECTANGLE PER PLACE the element is drawn, in document order.
    ///
    /// `elementHitRect(for:)` unions these, which is the right answer for "how big is this thing" and the wrong
    /// one for "where is this thing". An identity can be drawn in places that are nowhere near each other: a
    /// spanner clipped across a system break, and — since restatements began naming what they restate — a key
    /// signature whose declaration sits at the head of one system while its courtesy announcement sits at the
    /// trailing edge of the one before. Unioning those spans the gap between two systems, so a host floating a
    /// control beside the selection needs the pieces rather than their envelope.
    ///
    /// Empty for a target with no element identity or no laid-out geometry.
    public func elementHitRects(for target: ScoreHitTarget) -> [CGRect] {
        guard let id = target.elementID else { return [] }
        var result: [CGRect] = []
        func include(_ elements: [LayoutElement], base: CGPoint) {
            for element in elements where element.elementID == id {
                var combined: CGRect?
                for rect in elementRects(element) {
                    let shifted = rect.offsetBy(dx: base.x, dy: base.y)
                    combined = combined.map { $0.union(shifted) } ?? shifted
                }
                if let combined {
                    result.append(combined)
                }
            }
        }
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                )
                include(measure.elements, base: base)
                include(measure.markers, base: base)
                include(measure.jumps, base: base)
                include(measure.invisibleElements, base: base)
            }
            include(system.spanners, base: system.origin)
            include(system.invisibleSpanners, base: system.origin)
        }
        return result
    }

    /// Barlines use stroke/dot ink bounds; pedals, key signatures and time signatures use glyph ink bounds.
    /// Navigation uses unpadded shipped text rectangles or centered glyph ink, according to its renderer.
    /// Remaining kinds use skyline measurements: fermatas, breaths and articulations use glyph path bounds
    /// with the skyline helper's fallback; dynamics and tempo mix glyph and font metrics; hairpins, ottavas
    /// and voltas use coarse span reservations. No universal ink-coverage claim follows.
    private func elementRects(_ element: LayoutElement) -> [CGRect] {
        if let rects = arcInkRects(element) { return rects }
        if let rects = navigationRects(element) { return rects }
        switch element {
        case let .barLine(subtype, origin, halfHeight, _, _):
            return barLineInkRects(subtype: subtype, origin: origin, halfHeight: halfHeight)
        case let .spannerSegment(.pedal, from, to, _, _, _, _):
            return PedalInkGeometry.rects(from: from, to: to, metrics: document.metrics)
        case let .keySignature(sharps, flats, clef, naturals, origin, _):
            return keySignatureInkRects(sharps: sharps, flats: flats, clef: clef, naturals: naturals, origin: origin)
        case let .timeSignature(numerator, denominator, symbol, origin, _):
            return timeSignatureInkRects(numerator: numerator, denominator: denominator, symbol: symbol, origin: origin)
        default:
            return LayoutElementShape.shape(
                for: element, id: 0, xOffset: 0, metrics: document.metrics,
            )?.rects.map(\.rect) ?? []
        }
    }

    private func keySignatureInkRects(
        sharps: Int, flats: Int, clef: NotatedClef, naturals: [Int], origin: CGPoint,
    ) -> [CGRect] {
        let sp = document.metrics.sp
        let glyph = sharps > 0 ? SMuFLCodepoint.accidentalSharp : SMuFLCodepoint.accidentalFlat
        let steps = KeySignatureSteps.steps(sharps: sharps, flats: flats, clef: clef)
        let run = naturals.map { ($0, SMuFLCodepoint.accidentalNatural) } + steps.map { ($0, glyph) }
        return glyphInkRects(run.enumerated().map { index, entry in
            (entry.1, CGPoint(
                x: origin.x + CGFloat(index) * KeySignatureSteps.advance(sp: sp),
                y: origin.y + KeySignatureSteps.stepDy(step: entry.0, sp: sp),
            ))
        })
    }

    private func timeSignatureInkRects(
        numerator: Int, denominator: Int, symbol: TimeSignatureSymbol, origin: CGPoint,
    ) -> [CGRect] {
        let sp = document.metrics.sp
        if let glyph = TimeSignatureLayout.symbolCodepoint(symbol) {
            return glyphInkRects([(glyph, CGPoint(x: origin.x, y: origin.y + TimeSignatureLayout.symbolDy(sp: sp)))])
        }
        let offsets = TimeSignatureLayout.rowOffsets(numerator: numerator, denominator: denominator, sp: sp)
        let rows = [
            (numerator, offsets.numeratorOffsetX, TimeSignatureLayout.numeratorDy(sp: sp)),
            (denominator, offsets.denominatorOffsetX, TimeSignatureLayout.denominatorDy(sp: sp)),
        ]
        return glyphInkRects(rows.flatMap { value, dx, dy in
            String(value).enumerated().map { index, character in
                (SMuFLCodepoint.timeSigDigit(Int(String(character)) ?? 0), CGPoint(
                    x: origin.x + dx + CGFloat(index) * TimeSignatureLayout.digitAdvance(sp: sp),
                    y: origin.y + dy,
                ))
            }
        })
    }

    /// Matches the renderer's text-band vertical anchor and ink-width horizontal anchor.
    /// Missing glyph bounds produce no guessed box.
    func glyphInkRects(_ glyphs: [(UInt32, CGPoint)], anchorX: CGFloat = 0.5) -> [CGRect] {
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: document.metrics.glyphFontSize)
        let provider = FontMetrics.provider
        let baselineOffset = (provider.ascent(font: font) - provider.descent(font: font)) / 2
        return glyphs.compactMap { codepoint, origin in
            guard let box = provider.glyphPathBoundingBox(
                font: font, codepoint: UInt16(truncatingIfNeeded: codepoint),
            ), box.width > 0, box.height > 0 else { return nil }
            return CGRect(
                x: origin.x - anchorX * box.width, y: origin.y + baselineOffset - box.maxY,
                width: box.width, height: box.height,
            )
        }
    }

    /// Component ink boxes, using the same stroke positions, widths and dot sizes as the renderer.
    /// The spaces between separate strokes are not clickable. Dot boxes bound the painted circles.
    private func barLineInkRects(subtype: String?, origin: CGPoint, halfHeight: CGFloat) -> [CGRect] {
        let sp = document.metrics.sp
        let thin = sp * BarLineGeometry.thinThicknessSp
        let thick = sp * BarLineGeometry.thickThicknessSp
        func stroke(_ dx: CGFloat, width: CGFloat) -> CGRect {
            CGRect(
                x: origin.x + dx - width / 2,
                y: origin.y - halfHeight,
                width: width,
                height: halfHeight * 2,
            )
        }
        func dots(_ dx: CGFloat) -> [CGRect] {
            let size = sp * BarLineGeometry.repeatDotDiameterSp
            return [-sp / 2, sp / 2].map { dy in
                CGRect(
                    x: origin.x + dx - size / 2,
                    y: origin.y + dy - size / 2,
                    width: size,
                    height: size,
                )
            }
        }
        switch subtype {
        case "double":
            let dx = sp * BarLineGeometry.doubleStrokeDxSp
            return [stroke(-dx, width: thin), stroke(dx, width: thin)]
        case "end", "final":
            return [stroke(0, width: thin), stroke(sp * BarLineGeometry.endThickStrokeDxSp, width: thick)]
        case "start-repeat":
            return [stroke(0, width: thick), stroke(sp * BarLineGeometry.repeatSecondStrokeDxSp, width: thin)]
                + dots(sp * BarLineGeometry.repeatDotDxSp)
        case "end-repeat":
            return [stroke(0, width: thin), stroke(sp * BarLineGeometry.repeatSecondStrokeDxSp, width: thick)]
                + dots(-sp * BarLineGeometry.repeatDotDxSp)
        default:
            return [stroke(0, width: thin)]
        }
    }
}
