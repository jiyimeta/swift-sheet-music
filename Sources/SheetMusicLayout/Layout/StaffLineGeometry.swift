#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Per-staff line geometry — the overlay on score-global `StaffMetrics`.
///
/// `StaffMetrics` knows the staff *size* (one `sp`, shared by the whole
/// score); this knows how many lines a particular staff draws, and
/// therefore how tall it is, where its edges sit in `step` units, and
/// where its ledger lines begin.
///
/// Every line-count-dependent constant lives here. Adding MuseScore's
/// `stepOffset` or `lineDistance` later means changing `lineY` and the
/// step→Y conversion, and nothing else — every caller that goes
/// through this type keeps working unchanged. A TAB staff is a bigger
/// change than that: it drops ledger lines and largely drops the
/// notehead/step concept this type is built around, and can affect
/// barline spans too, so later tasks should not assume it slots in
/// here as cheaply as `stepOffset`/`lineDistance` do.
///
/// C++: the line-related slice of `mu::engraving::StaffType`.
public struct StaffLineGeometry: Sendable, Equatable {
    /// A standard five-line staff.
    public static let standard = StaffLineGeometry(lineCount: 5)

    /// Number of drawn lines, clamped to 1...16 (MuseScore's own
    /// `StaffType` range for a custom line count).
    public let lineCount: Int

    public init(lineCount: Int) {
        self.lineCount = min(max(lineCount, 1), 16)
    }

    /// Y of line `index` (0 = top line) relative to the staff origin.
    public func lineY(_ index: Int, sp: CGFloat) -> CGFloat {
        CGFloat(index) * sp
    }

    /// Distance from the top line to the bottom line. Zero for a
    /// one-line staff — there is nothing to span between a single line
    /// and itself. C++: `StaffType::staffHeight`.
    public func height(sp: CGFloat) -> CGFloat {
        CGFloat(lineCount - 1) * sp
    }

    /// `step` of the top line. Always 4, for every line count.
    ///
    /// `step` 0 is the middle line of the reference five-line staff;
    /// `step = 4 − (MuseScore line)`, and the top line is MuseScore
    /// line 0. This is fixed rather than derived from `lineCount`
    /// because MuseScore anchors note positions to the top line
    /// regardless of how many lines are drawn — `Note::updateRelLine`
    /// never consults `StaffType::lines()`. A 1-line or 3-line
    /// percussion staff still measures every note's height from the
    /// same top-line reference a 5-line staff uses; only where the
    /// *other* lines fall (via `bottomStep`) changes.
    public var topStep: Int {
        4
    }

    /// `step` of the bottom line. Each additional drawn line moves the
    /// bottom line one space (2 half-space `step` units) further from
    /// the fixed top line.
    public var bottomStep: Int {
        4 - 2 * (lineCount - 1)
    }

    /// First ledger position above the staff — fixed at MuseScore line
    /// −2 (one space above the top line) for every line count, because
    /// the top line's `step` never moves (see `topStep`).
    /// C++: `ChordLayout::updateLedgerLines`
    /// (`rendering/score/chordlayout.cpp:1287-1311`).
    public var firstLedgerStepAbove: Int {
        6
    }

    /// First ledger position below the staff — MuseScore line
    /// `lines() * 2`, one space below the bottom line. Unlike the
    /// above-staff case this does move with `lineCount`, because it is
    /// anchored to the bottom line rather than the fixed top line.
    ///
    /// C++: `ChordLayout::updateLedgerLines`
    /// (`rendering/score/chordlayout.cpp:1287-1311`) — the engraved-chord
    /// ledger-line pass. Not `TLayout::layoutShadowNote`
    /// (`rendering/score/tlayout.cpp:4593`), which lays out the
    /// note-input cursor preview, not actual chords.
    public var firstLedgerStepBelow: Int {
        bottomStep - 2
    }

    /// This staff's own vertical center, relative to the REFERENCE
    /// five-line middle line, in staff spaces. Zero for five lines;
    /// −1 sp for three; −2 sp for one.
    ///
    /// MuseScore centers exactly two header glyphs on the staff's own
    /// height rather than on the five-line frame: the percussion clefs
    /// (`TLayout`, `tlayout.cpp:1706-1710`,
    /// `yoff = lineDist * (lines - 1) * 0.5`) and the time signature
    /// (`tlayout.cpp:6095`, `yoff = spatium * (numOfLines - 1) * .5 *
    /// lineDist`). Both measure `yoff` from the TOP line; placement
    /// expresses their origins against the reference middle line, which
    /// sits 2 sp below the top line, so this is that `yoff` re-based.
    ///
    /// Pitched clefs and key signatures deliberately do NOT use this —
    /// `tlayout.cpp:1687` hardcodes `5 - ClefInfo::line(...)`, so a G
    /// clef on a three-line staff stays anchored where a five-line
    /// staff would put it, exactly like `topStep`.
    public var centerOffsetSp: CGFloat {
        CGFloat(lineCount - 1) / 2 - 2
    }

    /// The line a rest centers on before the voice-offset and
    /// whole/breve adjustments, counted in 1 sp steps down from the top
    /// line. 5 → 2 (the middle line), 3 → 1, 1 → 0.
    ///
    /// C++: `RestLayout::computeNaturalLine`
    /// (`rendering/score/restlayout.cpp:688-692`):
    /// `(lines % 2) ? floor(lines / 2) : ceil(lines / 2)`. Both branches
    /// collapse to integer `lines / 2` — floor is exact for odd counts,
    /// ceil for even — so the single expression below reproduces it for
    /// every line count.
    public var naturalRestLine: Int {
        lineCount / 2
    }

    /// Lines a WHOLE rest moves on top of `naturalRestLine`, given the
    /// multi-voice offset already applied to it (also in lines:
    /// −2 for an "up" voice, +2 for a "down" one, 0 when the measure
    /// has a single voice).
    ///
    /// C++: `RestLayout::computeWholeOrBreveRestOffset`
    /// (`rendering/score/restlayout.cpp:766-780`). The predicate is
    /// reproduced verbatim because it is not decomposable: it reads
    /// `lines` AND the voice offset together, and on a ONE-line staff
    /// with no voice offset it evaluates false — MuseScore leaves the
    /// whole rest ON the single line rather than hanging it from the
    /// line above, which is the five-line convention. Getting that
    /// wrong also changes which GLYPH is drawn, because
    /// `Rest::getSymbol` (`dom/rest.cpp:258-259`) picks the
    /// leger-line variant from `line < 0 || line >= lines`.
    ///
    /// The breve branch (`lineMove = +1` when `lines == 1`) is absent
    /// on purpose: `NoteDuration` has no breve case, so no input can
    /// reach it. Add it here — not at the call site — if one appears.
    /// **Scope.** MuseScore's predicate reads in full:
    ///
    ///     moveToLineAbove = (lines > 5)
    ///         || ((lines > 1 || vo == -1 || vo == 2)
    ///             && !(vo == -2 || vo == 1))
    ///
    /// The `!(vo == -2 || vo == 1)` exception also fires on staves that
    /// draw MORE than one line — an "up" voice's whole rest in a
    /// multi-voice measure should stay on the natural line — and we
    /// diverge from it there. That divergence is real but it is a
    /// FIVE-line behavior change with nothing to do with line counts:
    /// adopting it moves 31 of the 139 corpus renders instead of the 8
    /// that declare a non-five-line staff, i.e. 23 five-line scores.
    /// This task must leave five-line staves byte-identical, so only
    /// the `lines` half is adopted here. Tracked as a follow-up.
    public func wholeRestLineMove(voiceOffsetLines: Int) -> Int {
        // `lines > 5` moves unconditionally, and for 2...5 lines the
        // only case we diverge on is the one scoped out above, so
        // everything but a one-line staff keeps hanging the rest from
        // the line above.
        guard lineCount == 1 else { return -1 }
        let moveToLineAbove = (
            voiceOffsetLines == -1 || voiceOffsetLines == 2,
        )
            && !(voiceOffsetLines == -2 || voiceOffsetLines == 1)
        return moveToLineAbove ? -1 : 0
    }

    /// Vertical span of a barline on this staff, relative to the staff
    /// origin. A one-line staff is a special case: MuseScore spans it
    /// ±4 half-spaces (±2 `sp`) instead of over its (zero) height —
    /// otherwise a single-line staff's barline would collapse to a dot.
    /// C++: `dom/barline.cpp:256-274`,
    /// `BARLINE_SPAN_1LINESTAFF_FROM/TO`.
    public func barLineSpanY(sp: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        guard lineCount > 1 else { return (-sp * 2, sp * 2) }
        return (0, height(sp: sp))
    }
}
