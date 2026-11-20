#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Per-staff sizing derived from `ScoreViewOptions.staffSize`.
///
/// MuseScore / engraving convention: one "staff space" (sp) = one line
/// distance of a five-line staff. A staff is 4 sp tall.
public struct StaffMetrics: Sendable, Equatable {
    /// Total height of the five-line staff, in points. Equals 4 × sp.
    public let staffHeight: CGFloat
    /// One staff space in points (distance between adjacent staff lines).
    public let sp: CGFloat
    /// Host-selected engraving distances used by spacing calculations.
    public let spacing: EngravingSpacing

    /// Creates point-based metrics for a staff and its engraving spacing.
    ///
    /// Reconstruction sites that rescale for glyph magnification (grace / cue
    /// noteheads) deliberately omit `spacing` and receive `.standard`: those
    /// sites read only `glyphFontSize` and never call spacing functions.
    public init(
        staffSize: CGFloat,
        spacing: EngravingSpacing = .standard,
    ) {
        staffHeight = staffSize
        sp = staffSize / 4
        self.spacing = spacing
    }

    /// Thickness of a staff line: MuseScore's `staffLineWidth`, 0.11 sp (`styledef.cpp:286`). It was 0.13 sp until
    /// 2026-11-21, which drew every staff a fifth heavier than MuseScore's (folino owner's call).
    public var staffLineThickness: CGFloat {
        sp * 0.11
    }

    /// Thickness of a stem: MuseScore's `stemWidth`, 0.10 sp (`styledef.cpp:266`), scaled by a grace or cue
    /// chord's magnification where it is drawn, as MuseScore scales it. It was 0.12 sp until 2026-11-21.
    public var stemThickness: CGFloat {
        sp * 0.10
    }

    /// Thickness of a ledger line: MuseScore's `ledgerLineWidth`, 0.16 sp (`styledef.cpp:287`). It was 1.5 times the
    /// staff line (0.195 sp) until 2026-11-21.
    public var ledgerLineThickness: CGFloat {
        sp * 0.16
    }

    /// Thickness of a lyric's melisma line and of a lyric hyphen: MuseScore's `lyricsLineThickness` and
    /// `lyricsDashLineThickness`, both 0.1 sp (`styledef.cpp:122`, `:127`). Every renderer reads it here; until
    /// 2026-11-21 the draw program drew both 0.13 sp while Apple drew 0.1.
    public var lyricsLineThickness: CGFloat {
        sp * 0.1
    }

    /// Typical stem length for isolated notes: 3.5 sp.
    public var defaultStemLength: CGFloat {
        sp * 3.5
    }

    /// Font size for Bravura glyphs (pt). One em = 4 sp by SMuFL convention.
    public var glyphFontSize: CGFloat {
        sp * 4
    }

    /// Horizontal space allocated per quarter note (pre-stretch).
    /// Calibrated against MuseScore's
    /// `Sid::measureSpacing = 1.5_sp` default, modulated by the
    /// "shortest note in this measure" heuristic; for the typical
    /// quarter beat the engraving target is ~1.6 sp. The previous
    /// 4 sp value over-stretched measures, especially under
    /// lyrics, and reduced systems-per-page by ~40 %.
    public var spacePerQuarter: CGFloat {
        sp * spacing.spacePerQuarter
    }

    /// Default Y origin for chord symbols, in points (relative to
    /// the staff top). Negative = above the staff. -2.5 sp matches
    /// MuseScore's `Sid::chordSymbolAPlacement = above` with the
    /// default 0.5 sp offset clear of the staff.
    public var harmonyPlacementAbove: CGFloat {
        sp * -2.5
    }
}
