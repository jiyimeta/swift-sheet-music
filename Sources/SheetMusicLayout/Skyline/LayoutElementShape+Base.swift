#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Base-skyline rect builders for `LayoutElementShape`. Split out of
/// `LayoutElementShape.swift` to keep both files under the project's
/// 400-line file-length limit without a blanket disable.
extension LayoutElementShape {
    /// Rects for elements that form the immovable base skyline.
    static func baseRects(
        for element: LayoutElement,
        kind: ShapeItemKind, metrics: StaffMetrics,
    ) -> [CGRect] {
        let sp = metrics.sp
        switch element {
        case let .chord(
            notes, _, stem, stemOrigin, _, _, _, _, stemExtension, _, mag,
        ):
            return chordRects(
                notes: notes, stem: stem, stemOrigin: stemOrigin,
                stemExtension: stemExtension, mag: mag, metrics: metrics,
            )
        case let .graceChord(notes, _, stem, stemOrigin, _, _, mag, _):
            // `relativeX` is already baked into `notes[].origin.x` and
            // `stemOrigin.x` at emission (`LayoutEngine+Placement`
            // passes `atX: chordX + relX`), so it must NOT be applied
            // again here.
            return chordRects(
                notes: notes, stem: stem, stemOrigin: stemOrigin,
                stemExtension: 0, mag: mag, metrics: metrics,
            )
        case let .beam(from, to, _, level, _):
            let thickness = sp * 0.5 * CGFloat(max(1, level))
            return [spanRect(from, to, thickness: thickness)]
        case let .rest(_, p, _, _, _):
            return [CGRect(
                x: p.x - sp * 0.6, y: p.y - sp,
                width: sp * 1.2, height: sp * 2,
            )]
        case let .note(_, _, _, _, p, _, _, _):
            return [noteheadRect(center: p, mag: 1, sp: sp)]
        case .articulation, .fermata, .breath, .tieArc, .tupletLabel,
             .glissandoLine, .arpeggioWiggle, .chordLine, .tremoloBars:
            return decorationRects(for: element, sp: sp)
        case .ledgerLine:
            // `LayoutElementShape.kind(of:)` already returns `nil` for
            // `.ledgerLine`, so `shape(for:)` never calls this far — the
            // ledger line's ink is part of its chord's skyline entry, not
            // its own. Kept explicit rather than falling through the
            // `default` below, which is for staff-internal elements
            // (clef / key / time / bar line / …) that `.ledgerLine` is
            // unrelated to.
            return []
        default:
            return staffInternalRects(
                element: element, kind: kind, metrics: metrics,
            )
        }
    }

    /// Rects for per-chord decorations that don't need the full chord
    /// context: articulations, fermatas, breaths, tie arcs, tuplet
    /// labels, glissando lines, arpeggio wiggles, chord lines, and
    /// tremolo bars. Split out of `baseRects` to keep both functions
    /// under the 60-line limit.
    static func decorationRects(
        for element: LayoutElement, sp: CGFloat,
    ) -> [CGRect] {
        switch element {
        case let .articulation(artKind, p, isAbove):
            return [smuflGlyphRect(
                codepoint: ArticulationGlyph.codepoint(
                    kind: artKind, isAbove: isAbove,
                ),
                center: p, sp: sp,
            )]
        case let .fermata(subtype, p):
            return [smuflGlyphRect(
                codepoint: FermataGlyph.codepoint(forSubtype: subtype),
                center: p, sp: sp,
            )]
        case let .breath(breathKind, p):
            return [smuflGlyphRect(
                codepoint: BreathGlyph.codepoint(forKind: breathKind),
                center: p, sp: sp,
            )]
        case let .tieArc(from, to, above):
            let apex = above ? min(from.y, to.y) - sp : max(from.y, to.y) + sp
            return [spanRect(
                CGPoint(x: from.x, y: apex), to, thickness: sp * 0.2,
            )]
        case let .tupletLabel(from, to, _, _, _, _):
            return [spanRect(from, to, thickness: sp * 1.5)]
        case let .glissandoLine(from, to, _, _):
            return [spanRect(from, to, thickness: sp * 0.3)]
        case let .arpeggioWiggle(top, bottom, _):
            return [spanRect(top, bottom, thickness: sp)]
        case let .chordLine(shape, origin, _):
            return [chordLineRect(shape: shape, origin: origin, sp: sp)]
        case let .tremoloBars(anchor, barCount):
            return [tremoloRect(
                anchor: anchor, barCount: barCount, sp: sp,
            )]
        default:
            return []
        }
    }
}

extension LayoutElementShape {
    /// Noteheads + stem + accidentals + above/below tie arcs. Every
    /// rect here is tagged with the chord's own `ShapeItem` by
    /// `LayoutElementShape.shape`, so an accidental is part of its
    /// chord for the ignore rules — there is no `.accidental` kind.
    ///
    /// Ledger lines and flags are deliberately absent: a ledger line
    /// only adds horizontal width at a notehead's own Y (already inside
    /// the notehead rect for skyline purposes), and a flag extends
    /// sideways from the stem tip rather than beyond it.
    static func chordRects(
        notes: [LayoutChordNote], stem: StemDirection,
        stemOrigin: CGPoint, stemExtension: CGFloat,
        mag: CGFloat, metrics: StaffMetrics,
    ) -> [CGRect] {
        let sp = metrics.sp
        var rects: [CGRect] = []
        for n in notes {
            let center = CGPoint(
                x: n.origin.x + n.mirrorDx(stem: stem, sp: sp * mag),
                y: n.origin.y,
            )
            rects.append(noteheadRect(center: center, mag: mag, sp: sp))
            if n.accidental != nil {
                rects.append(CGRect(
                    x: n.origin.x - sp * 2.2, y: n.origin.y - sp * 1.5,
                    width: sp * 1.4, height: sp * 3,
                ))
            }
        }
        let ys = notes.map(\.origin.y)
        let stemLength = metrics.defaultStemLength * mag + stemExtension
        if let top = ys.min(), let bottom = ys.max() {
            let tipY = stem == .up
                ? bottom - stemLength
                : top + stemLength
            let stemTop = min(tipY, top)
            let stemBottom = max(tipY, bottom)
            rects.append(CGRect(
                x: stemOrigin.x - sp * 0.1, y: stemTop,
                width: sp * 0.2, height: stemBottom - stemTop,
            ))
        }
        if let tieTop = aboveTieApexY(
            notes: notes, stem: stem, sp: sp,
        ), let x = ys.isEmpty ? nil : notes.map(\.origin.x).min() {
            let maxX = notes.map(\.origin.x).max() ?? x
            rects.append(CGRect(
                x: x, y: tieTop,
                width: max(sp, maxX - x), height: sp * 0.6,
            ))
        }
        return rects
    }

    static func noteheadRect(
        center: CGPoint, mag: CGFloat, sp: CGFloat,
    ) -> CGRect {
        // Bravura noteheadBlack: 1.18 sp wide × 1.0 sp tall.
        let w = sp * 1.18 * mag
        let h = sp * mag
        return CGRect(
            x: center.x - w / 2, y: center.y - h / 2,
            width: w, height: h,
        )
    }

    /// Smallest (highest) Y an above-arcing tie on this chord reaches,
    /// or `nil` when no note carries one. Tie-direction rule and the
    /// 1.6 sp apex constant are carried over verbatim from the retired
    /// `LayoutEngine.aboveTieExtent`.
    static func aboveTieApexY(
        notes: [LayoutChordNote], stem: StemDirection, sp: CGFloat,
    ) -> CGFloat? {
        let steps = notes.map(\.step)
        guard let maxStep = steps.max(), let minStep = steps.min()
        else { return nil }
        let isSingle = maxStep == minStep
        var top: CGFloat?
        for n in notes where n.tieForward != nil || n.tieBack != nil {
            let above: Bool
            if isSingle {
                above = stem == .down
            } else if n.step == maxStep {
                above = true
            } else if n.step == minStep {
                above = false
            } else {
                above = stem == .down
            }
            guard above else { continue }
            let apex = n.origin.y - sp * 1.6
            top = min(top ?? apex, apex)
        }
        return top
    }

    /// Axis-aligned rect covering the segment `a`→`b`, inflated
    /// vertically by `thickness`.
    static func spanRect(
        _ a: CGPoint, _ b: CGPoint, thickness: CGFloat,
    ) -> CGRect {
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y)
        return CGRect(
            x: minX, y: minY - thickness / 2,
            width: maxX - minX, height: maxY - minY + thickness,
        )
    }

    static func chordLineRect(
        shape: ChordLineShape, origin: CGPoint, sp: CGFloat,
    ) -> CGRect {
        switch shape {
        case let .path(segments):
            let box = ChordLineGeometry.boundingBox(of: segments)
            return CGRect(
                x: origin.x + box.minX, y: origin.y + box.minY,
                width: max(sp * 0.5, box.width),
                height: max(sp * 0.5, box.height),
            )
        case .glyph:
            return CGRect(
                x: origin.x - sp, y: origin.y - sp,
                width: sp * 2, height: sp * 2,
            )
        }
    }

    static func tremoloRect(
        anchor: TremoloAnchor, barCount: Int, sp: CGFloat,
    ) -> CGRect {
        let height = sp * (0.5 + 0.5 * CGFloat(max(1, barCount)))
        switch anchor {
        case let .single(c):
            return CGRect(
                x: c.x - sp, y: c.y - height / 2,
                width: sp * 2, height: height,
            )
        case let .between(left, right):
            return spanRect(left, right, thickness: height)
        }
    }

    /// Clef / key / time / bar line / measure repeat / multi-measure
    /// rest — all live inside or across the staff, so `Skyline.add`'s
    /// filter usually drops them. A coarse rect is sufficient.
    ///
    /// **The clef's `sp * 3` half-height is load-bearing for measure
    /// numbers.** A G clef reaches well above the staff, so this rect
    /// is the only north-side obstacle in most first measures. Its top
    /// lands at `staffTop − 1 sp`, and a measure number's `maxY` sits
    /// at exactly `staffTop − 1.5 sp`, giving `overlap` = `−0.5 sp` =
    /// `−minDistance` — so `overlap > -minDistance` is false by exactly
    /// zero margin and the number keeps its emitted Y. Replacing this
    /// approximation with the clef's real ink (which is taller) would
    /// raise EVERY measure number in EVERY score. Change it only
    /// together with the measure-number default position.
    static func staffInternalRects(
        element: LayoutElement, kind: ShapeItemKind,
        metrics: StaffMetrics,
    ) -> [CGRect] {
        let sp = metrics.sp
        let p: CGPoint
        // A barline reports the span the engine gave it, so the
        // autoplace box tracks a one- or three-line staff's shorter
        // stroke instead of a fixed 4 sp. Everything else keeps the
        // five-line approximation.
        var barLineHalfHeight: CGFloat?
        switch element {
        case let .clef(_, origin, _),
             let .keySignature(_, _, origin),
             let .timeSignature(_, _, origin),
             let .measureRepeat(_, origin),
             let .multiMeasureRest(_, origin):
            p = origin
        case let .barLine(_, origin, half):
            p = origin
            barLineHalfHeight = half
        default:
            return []
        }
        let halfWidth: CGFloat = kind == .barLine ? sp * 0.2 : sp * 1.5
        let halfHeight: CGFloat = barLineHalfHeight
            ?? (kind == .clef ? sp * 3 : sp * 2)
        return [CGRect(
            x: p.x - halfWidth, y: p.y - halfHeight,
            width: halfWidth * 2, height: halfHeight * 2,
        )]
    }
}
