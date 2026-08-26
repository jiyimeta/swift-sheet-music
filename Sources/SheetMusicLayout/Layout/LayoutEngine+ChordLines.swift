#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension LayoutEngine {
    /// Build the `.chordLine` layout elements for one chord, mirroring
    /// MuseScore's `TLayout::layoutChordLine`
    /// (`rendering/score/tlayout.cpp`).
    ///
    /// Upstream measures the attachment X against the chord's full
    /// `Shape` (minus the chord lines / harmony / lyrics themselves).
    /// We approximate that with the notehead extents plus the
    /// augmentation dots, which is the same simplification the
    /// articulation and arpeggio passes already make — noteheads and
    /// dots are the only chord geometry that actually reaches the
    /// horizontal band a chord line occupies.
    ///
    /// Returns visible and invisible elements separately so the caller
    /// can route hidden lines into the `showsInvisibleElements`
    /// overlay, matching the arpeggio pass.
    static func chordLineElements(
        for chordLines: [ChordLine],
        chordNotes: [LayoutChordNote],
        chordX: CGFloat,
        dots: Int,
        stem: StemDirection,
        staffMidY: CGFloat,
        mag: CGFloat,
        metrics: StaffMetrics,
    ) -> (visible: [LayoutElement], invisible: [LayoutElement]) {
        guard !chordLines.isEmpty else { return ([], []) }
        var visible: [LayoutElement] = []
        var invisible: [LayoutElement] = []
        for line in chordLines {
            let element = chordLineElement(
                for: line,
                chordNotes: chordNotes,
                chordX: chordX,
                dots: dots,
                stem: stem,
                staffMidY: staffMidY,
                mag: mag,
                metrics: metrics,
            )
            if line.visible {
                visible.append(element)
            } else {
                invisible.append(element)
            }
        }
        return (visible, invisible)
    }

    private static func chordLineElement(
        for line: ChordLine,
        chordNotes: [LayoutChordNote],
        chordX: CGFloat,
        dots: Int,
        stem: StemDirection,
        staffMidY: CGFloat,
        mag: CGFloat,
        metrics: StaffMetrics,
    ) -> LayoutElement {
        let sp = metrics.sp
        // Anchor note: the one the line was bound to, else the chord's
        // up-note (C++: `chord()->findNote(note()->pitch())` falling
        // back to `chord()->upNote()`). Up = smallest Y on screen.
        let anchorNote = line.noteIndex
            .flatMap { chordNotes.indices.contains($0) ? chordNotes[$0] : nil }
            ?? chordNotes.min { $0.origin.y < $1.origin.y }
        let noteY = anchorNote?.origin.y ?? staffMidY

        var origin = CGPoint(
            x: attachmentX(
                for: line, chordNotes: chordNotes, chordX: chordX,
                dots: dots, stem: stem, sp: sp,
            ),
            y: noteY + (line.isBelow ? 1 : -1)
                * ChordLineGeometry.verticalOffsetSp * sp,
        )

        guard line.isWavy else {
            let segments = line.hasUserPath
                ? ChordLineGeometry.userPath(line.path, sp: sp)
                : ChordLineGeometry.defaultPath(for: line, sp: sp, mag: mag)
            return .chordLine(
                shape: .path(segments),
                origin: origin,
                thickness: ChordLineGeometry.thickness(sp: sp, mag: mag),
            )
        }

        // Wavy variants draw a single SMuFL glyph. Upstream nudges the
        // element by the glyph's own bbox so the wiggle straddles the
        // notehead's centre line, then draws it rotated by ±1°.
        let codepoint = ChordLineGeometry.waveCodepoint(kind: line.kind)
        let box = ChordLineGeometry.waveGlyphBox(codepoint: codepoint, sp: sp)
        origin.y += line.isBelow ? box.height - sp * 0.125 : sp * 0.075
        if line.isToTheLeft { origin.x -= box.width }
        return .chordLine(
            shape: .glyph(
                codepoint: codepoint,
                rotationDegrees: ChordLineGeometry
                    .waveRotationDegrees(kind: line.kind),
            ),
            origin: ChordLineGeometry.waveGlyphCenter(
                baselineOrigin: origin, codepoint: codepoint, sp: sp,
            ),
            thickness: ChordLineGeometry.thickness(sp: sp, mag: mag),
        )
    }

    /// X where the line meets the chord. C++: the `chordEdge` block of
    /// `layoutChordLine` — one third of a space clear of the chord on
    /// the relevant side, and never left of an augmentation dot.
    private static func attachmentX(
        for line: ChordLine,
        chordNotes: [LayoutChordNote],
        chordX: CGFloat,
        dots: Int,
        stem: StemDirection,
        sp: CGFloat,
    ) -> CGFloat {
        let horOffset = ChordLineGeometry.horizontalOffsetSp * sp
        let halfExtent = noteheadHalfExtent(sp: sp)
        let centers = chordNotes.map {
            $0.origin.x + $0.mirrorDx(stem: stem, sp: sp)
        }
        if line.isToTheLeft {
            let leftEdge = (centers.min() ?? chordX) - halfExtent
            return leftEdge - horOffset
        }
        var rightEdge = (centers.max() ?? chordX) + halfExtent
        if dots > 0 {
            // "Always place lines to the right of dots" — upstream.
            let lastDotCenter = (centers.max() ?? chordX)
                + DotGeometry.firstOffsetSp * sp
                + CGFloat(dots - 1) * DotGeometry.spacingSp * sp
            rightEdge = max(rightEdge, lastDotCenter + DotGeometry.radiusSp * sp)
        }
        return rightEdge + horOffset
    }
}
