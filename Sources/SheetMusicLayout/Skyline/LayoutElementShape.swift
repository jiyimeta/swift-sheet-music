// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// `LayoutElement` → `LayoutShape`. This is where the quality of the
/// skyline is decided: text extents come from `FontMetrics.provider`
/// and SMuFL glyph extents from `glyphPathBoundingBox`, rather than
/// the character-count constants the retired `LayoutEngine+Extents`
/// helpers used.
///
/// All rects are produced in MEASURE-LOCAL coordinates and shifted by
/// `xOffset` (the measure's accumulated `xCursor`) in `shape`.
enum LayoutElementShape {
    /// Category of `element`, or `nil` when it must not participate in
    /// the skyline at all: `.staffName` lives in the gutter, and slurs
    /// / vibrato already have dedicated placement passes that consult
    /// chord extents directly.
    static func kind(of element: LayoutElement) -> ShapeItemKind? {
        switch element {
        case .staffName: nil
        case .chord: .chord
        case .graceChord: .graceChord
        case .beam: .beam
        case .rest: .rest
        case .note: .note
        case .articulation: .articulation
        case .fermata: .fermata
        case .breath: .breath
        case .tieArc: .tie
        case .tupletLabel: .tupletLabel
        case .barLine: .barLine
        case .clef: .clef
        case .keySignature: .keySignature
        case .timeSignature: .timeSignature
        case .measureRepeat: .measureRepeat
        case .multiMeasureRest: .multiMeasureRest
        case .tremoloBars: .tremolo
        case .chordLine: .chordLine
        case .arpeggioWiggle: .arpeggio
        case .glissandoLine: .glissando
        case .measureNumber: .measureNumber
        case .harmony: .harmony
        case .rehearsalMark: .rehearsalMark
        case .marker: .marker
        case .jump: .jump
        case .lyricsMelisma: .lyricsMelisma
        case .lyricHyphen: .lyricHyphen
        case let .staffText(_, _, _, isSystemText):
            isSystemText ? .systemText : .staffText
        case let .textMark(markKind, _, _):
            switch markKind {
            case .dynamic: .dynamics
            case .tempo: .tempo
            case .lyrics: .lyrics
            }
        case let .spannerSegment(spannerKind, _, _, _, _, _):
            switch spannerKind {
            case .slur, .vibrato: nil
            case .volta: .volta
            case .hairpinOpen, .hairpinClose: .hairpin
            case .pedal: .pedal
            case .ottava: .ottava
            case .textLine: .textLine
            }
        }
    }

    /// Synthetic rect for the staff itself, spanning the system's
    /// horizontal extent. Registered first so `Skyline.add`'s filter
    /// has its reference edges.
    static func staffRect(
        xMin: CGFloat, xMax: CGFloat,
        staffMidY: CGFloat, metrics: StaffMetrics,
    ) -> ShapeRect {
        ShapeRect(
            rect: CGRect(
                x: xMin, y: staffMidY - metrics.sp * 2,
                width: max(0, xMax - xMin),
                height: metrics.staffHeight,
            ),
            item: ShapeItem(kind: .staff, id: -1),
        )
    }

    /// Ink rect of a SMuFL glyph drawn with a `.center` anchor at
    /// `center`. Mirrors the baseline math in `FermataGlyphMetrics`:
    /// the anchor puts the typographic centre at `center.y`, so the
    /// baseline sits `(ascent − descent) / 2` below it, and the glyph
    /// path bbox is measured relative to that baseline.
    static func smuflGlyphRect(
        codepoint: UInt32, center: CGPoint, sp: CGFloat,
    ) -> CGRect {
        // pointSize 4 ⇒ 1 em = 4 units ⇒ 1 unit = 1 sp.
        let em = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        let provider = FontMetrics.provider
        let baselineFromCenter =
            (provider.ascent(font: em) - provider.descent(font: em)) / 2
        guard let bbox = provider.glyphPathBoundingBox(
            font: em, codepoint: UInt16(truncatingIfNeeded: codepoint),
        ), bbox.width > 0, bbox.height > 0 else {
            return CGRect(
                x: center.x - sp * 0.5, y: center.y - sp * 0.5,
                width: sp, height: sp,
            )
        }
        let top = center.y + (baselineFromCenter - bbox.maxY) * sp
        let bottom = center.y + (baselineFromCenter - bbox.minY) * sp
        return CGRect(
            x: center.x - bbox.width * sp / 2,
            y: top,
            width: bbox.width * sp,
            height: max(0, bottom - top),
        )
    }

    /// Full shape of `element` in SYSTEM-X / staff-local-Y coordinates.
    /// `nil` when the element is excluded from the skyline.
    static func shape(
        for element: LayoutElement, id: Int,
        xOffset: CGFloat, metrics: StaffMetrics,
    ) -> LayoutShape? {
        guard let kind = kind(of: element) else { return nil }
        let rects = AutoplaceRules.isAutoplaced(kind)
            ? autoplacedRects(for: element, kind: kind, metrics: metrics)
            : baseRects(for: element, kind: kind, metrics: metrics)
        guard !rects.isEmpty else { return nil }
        let item = ShapeItem(kind: kind, id: id)
        return LayoutShape(rects: rects.map {
            ShapeRect(
                rect: CGRect(
                    x: $0.minX + xOffset, y: $0.minY,
                    width: $0.width, height: $0.height,
                ),
                item: item,
            )
        })
    }

    /// Temporary stub — Task 5 replaces this with the autoplaced text /
    /// spanner shapes (dynamics, lyrics, tempo, harmony, staff/system
    /// text, hairpins, pedal, ottava, text lines, volta, rehearsal
    /// marks, markers, jumps, measure numbers).
    static func autoplacedRects(
        for _: LayoutElement, kind _: ShapeItemKind, metrics _: StaffMetrics,
    ) -> [CGRect] {
        []
    }
}

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
        case let .graceChord(notes, _, stem, stemOrigin, relativeX, _, mag, _):
            return chordRects(
                notes: notes, stem: stem,
                stemOrigin: CGPoint(
                    x: stemOrigin.x + relativeX, y: stemOrigin.y,
                ),
                stemExtension: 0, mag: mag, metrics: metrics,
            ).map {
                CGRect(
                    x: $0.minX + relativeX, y: $0.minY,
                    width: $0.width, height: $0.height,
                )
            }
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
    /// Noteheads + stem + accidentals + above/below tie arcs.
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
    static func staffInternalRects(
        element: LayoutElement, kind: ShapeItemKind,
        metrics: StaffMetrics,
    ) -> [CGRect] {
        let sp = metrics.sp
        let p: CGPoint
        switch element {
        case let .clef(_, origin, _),
             let .keySignature(_, _, origin),
             let .timeSignature(_, _, origin),
             let .barLine(_, origin),
             let .measureRepeat(_, origin),
             let .multiMeasureRest(_, origin):
            p = origin
        default:
            return []
        }
        let halfWidth: CGFloat = kind == .barLine ? sp * 0.2 : sp * 1.5
        let halfHeight: CGFloat = kind == .clef ? sp * 3 : sp * 2
        return [CGRect(
            x: p.x - halfWidth, y: p.y - halfHeight,
            width: halfWidth * 2, height: halfHeight * 2,
        )]
    }
}
