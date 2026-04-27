import CoreGraphics

/// Per-staff sizing derived from `ScoreViewOptions.staffSize`.
///
/// MuseScore / engraving convention: one "staff space" (sp) = one line
/// distance of a five-line staff. A staff is 4 sp tall.
@available(macOS 15.0, iOS 16.0, *)
public struct StaffMetrics: Sendable, Equatable {
    /// Total height of the five-line staff, in points. Equals 4 × sp.
    public let staffHeight: CGFloat
    /// One staff space in points (distance between adjacent staff lines).
    public let sp: CGFloat

    public init(staffSize: CGFloat) {
        self.staffHeight = staffSize
        self.sp = staffSize / 4
    }

    /// Thickness of a staff line. Engraving: typically 0.13 sp.
    public var staffLineThickness: CGFloat { sp * 0.13 }
    /// Thickness of a stem. Engraving: typically 0.12 sp.
    public var stemThickness: CGFloat { sp * 0.12 }
    /// Typical stem length for isolated notes: 3.5 sp.
    public var defaultStemLength: CGFloat { sp * 3.5 }
    /// Font size for Bravura glyphs (pt). One em = 4 sp by SMuFL convention.
    public var glyphFontSize: CGFloat { sp * 4 }
    /// Horizontal space allocated per quarter note (pre-stretch).
    /// Calibrated against MuseScore's
    /// `Sid::measureSpacing = 1.5_sp` default, modulated by the
    /// "shortest note in this measure" heuristic; for the typical
    /// quarter beat the engraving target is ~1.6 sp. The previous
    /// 4 sp value over-stretched measures, especially under
    /// lyrics, and reduced systems-per-page by ~40 %.
    public var spacePerQuarter: CGFloat { sp * 1.6 }
}
