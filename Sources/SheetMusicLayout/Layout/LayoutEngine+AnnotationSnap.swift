#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// An expression placed below the staff with autoplace on, remembered while the voice is emitted so the dynamics
    /// of its beat are in `out` when it is snapped.
    struct ExpressionSnapAnchor {
        let outIndex: Int
        /// The chord the expression is attached to (`attachmentAnchor`): a dynamic attached to the same chord is of the
        /// same segment and track, MuseScore's condition.
        let attachedTo: VoiceElementID
        /// `<snapToDynamics>` (MuseScore's default true): the pair also shares a baseline. The x snap is unconditional.
        let sharesBaseline: Bool
    }

    /// MuseScore moves an expression so its bbox starts `padding` right of the visible dynamic of the same segment and
    /// voice (`TLayout::layoutExpression`, `tlayout.cpp:1857-1880`; `Expression::computeDynamicExpressionDistance`,
    /// `dom/expression.cpp:78-91`): `padding` is 0.2 sp after a dynamic whose text ends in an f, else 0.5 sp, scaled by
    /// `0.5 × (symbolScale + size / 10)` — 1 for the default dynamic and expression styles, so unscaled here. It also
    /// aligns a snapped pair (`snapToDynamics`) on the optical centre of both — baseline minus half an x-height,
    /// 0.46 sp for a dynamic (`AlignmentLayout::yOpticalCenter`, `alignmentlayout.cpp:194-222`, reached through
    /// `alignItemsWithTheirSnappingChain`, `:94`). Both x-heights are about 0.9 sp, so the centres coincide to a few
    /// hundredths of a space when the baselines do: the expression's first baseline is put on the dynamic's.
    static func snapExpressions(
        _ anchors: [ExpressionSnapAnchor], out: inout [LayoutElement], metrics: StaffMetrics,
    ) {
        for anchor in anchors where out.indices.contains(anchor.outIndex) {
            guard case let .staffText(text, _, _, style, _, _, properties, _, rich) = out[anchor.outIndex],
                  let beside = dynamicBeside(attachedTo: anchor.attachedTo, in: out, metrics: metrics),
                  let expressionBox = LayoutElementShape.shape(
                      for: out[anchor.outIndex], id: 0, xOffset: 0, metrics: metrics,
                  )?.bbox
            else { continue }
            let padding = (beside.endsInForte ? 0.2 : 0.5) * metrics.sp
            let shifted = translateX(
                element: out[anchor.outIndex], dx: beside.right + padding - expressionBox.minX,
            )
            guard anchor.sharesBaseline else {
                out[anchor.outIndex] = shifted
                continue
            }
            // The first baseline goes where the dynamic's is.
            let font = TextInkGeometry.font(for: style, overrides: properties, metrics: metrics)
            let baseline = CGPoint(x: 0, y: beside.baselineY)
            let target = rich.map { textPlacementOrigin(rich: $0, baseline: baseline, center: false) }
                ?? textPlacementOrigin(text: text, font: font, baseline: baseline, center: false)
            guard case let .staffText(shown, p, color, shownStyle, tid, placement, props, identity, richText) = shifted
            else { continue }
            out[anchor.outIndex] = .staffText(
                text: shown, origin: CGPoint(x: p.x, y: target.y), color: color, style: shownStyle, anchor: tid,
                placement: placement, properties: props, identity: identity, richText: richText,
            )
        }
    }

    /// The right edge, forte-ness and baseline of the visible dynamic attached to the chord `attachedTo` — matched by
    /// that anchor rather than by x, since a dynamic opening a measure is placed from the header's content edge, not
    /// its chord's column. Dynamics are always placed below the staff at this revision, so the dynamic is on the
    /// expression's side. `endsInForte` is `Expression::computeDynamicExpressionDistance`'s test (`xmlText` ends in
    /// `<sym>dynamicForte</sym>`): a plain dynamic's subtype ends in "f" (f, mf, ff, sf, rf …), a rich one (W4) has a
    /// last run that is the `dynamicForte` glyph.
    private static func dynamicBeside(
        attachedTo: VoiceElementID, in out: [LayoutElement], metrics: StaffMetrics,
    ) -> (right: CGFloat, endsInForte: Bool, baselineY: CGFloat)? {
        for element in out {
            guard case let .textMark(.dynamic(anchor), text, origin, rich) = element,
                  anchor == attachedTo,
                  let box = LayoutElementShape.shape(for: element, id: 0, xOffset: 0, metrics: metrics)?.bbox
            else { continue }
            if let rich {
                // W4 hangs a rich dynamic by `LayoutRichText.anchor(for: .dynamic)`, first baseline on the plain
                // glyphs' baseline: invert `LayoutRichText.origin(firstBaselineAt:anchor:)`.
                let baseline = origin.y + rich.firstBaseline
                    - LayoutRichText.anchor(for: .dynamic).y * rich.size.height
                let lastRun = rich.lines.last?.runs.last?.content
                var endsInForte = false
                if case let .symbol(code)? = lastRun { endsInForte = code == SMuFLCodepoint.byName("dynamicForte") }
                return (box.maxX, endsInForte, baseline)
            }
            // A plain dynamic hangs by the vertical centre of its 4 sp music-font box (anchor (0, 0.5)).
            let glyphFont = LayoutFont(face: SMuFLFamily.bravura, pointSize: metrics.sp * 4)
            let baseline = LayoutElementShape.baselineY(font: glyphFont, originY: origin.y, anchor: .leadingCenter)
            return (box.maxX, text.hasSuffix("f"), baseline)
        }
        return nil
    }
}
