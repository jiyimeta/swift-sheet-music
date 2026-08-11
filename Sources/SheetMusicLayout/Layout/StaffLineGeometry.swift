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
/// `stepOffset` or `lineDistance` later — or a TAB staff, which changes
/// both the line spacing and what a "line" even represents — means
/// changing `lineY` and the step→Y conversion, and nothing else; every
/// caller that goes through this type keeps working unchanged.
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
