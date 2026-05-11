import CoreGraphics
import Foundation
import SheetMusicCore

/// Page geometry expressed in **points** (Core Graphics units) —
/// already converted from MuseScore's mixed inch / mm storage.
///
/// `EngravingPage` is what `PDFExporter` works with internally. The
/// public `PDFExporter.Options` exposes `PageGeometry.fromScore` (the
/// default), which resolves to one of these via
/// `EngravingPage.from(_:)`.
public struct EngravingPage: Sendable, Equatable {
    public var size: CGSize
    public var oddMargins: PageMargins
    public var evenMargins: PageMargins
    /// `true` → odd pages use `oddMargins`, even pages use
    /// `evenMargins`. `false` → every page uses `oddMargins`.
    public var twosided: Bool

    public init(
        size: CGSize,
        oddMargins: PageMargins,
        evenMargins: PageMargins,
        twosided: Bool,
    ) {
        self.size = size
        self.oddMargins = oddMargins
        self.evenMargins = twosided ? evenMargins : oddMargins
        self.twosided = twosided
    }

    /// Pick the active margins for `pageIndex` (0-based). Page 0 is
    /// odd (page 1 in human counting); two-sided alternation
    /// follows from there. Mirrors
    /// `engraving/dom/page.cpp::Page::isOdd`.
    public func margins(forPageIndex pageIndex: Int) -> PageMargins {
        guard twosided else { return oddMargins }
        return (pageIndex % 2 == 0) ? oddMargins : evenMargins
    }

    /// 8.5" × 11", uniform 36 pt margins, single-sided. Useful when a
    /// caller wants a quick override without thinking in MuseScore
    /// units.
    public static let usLetter = EngravingPage(
        size: CGSize(width: 612, height: 792),
        oddMargins: PageMargins(uniform: 36),
        evenMargins: PageMargins(uniform: 36),
        twosided: false,
    )

    /// MuseScore's default A4 with 15 mm margins, two-sided.
    /// Equivalent to `EngravingPage.from(.museScoreA4)`.
    public static let a4 = EngravingPage.from(.museScoreA4)

    /// Convert a `PageLayout` (MuseScore native units: inches) into a
    /// point-based `EngravingPage`.
    public static func from(_ layout: PageLayout) -> EngravingPage {
        let inchToPt = 72.0
        let oddRight = layout.oddRightMargin * inchToPt
        let evenRight = layout.evenRightMargin * inchToPt
        return EngravingPage(
            size: CGSize(
                width: layout.width * inchToPt,
                height: layout.height * inchToPt,
            ),
            oddMargins: PageMargins(
                top: layout.oddTopMargin * inchToPt,
                leading: layout.oddLeftMargin * inchToPt,
                bottom: layout.oddBottomMargin * inchToPt,
                trailing: oddRight,
            ),
            evenMargins: PageMargins(
                top: layout.evenTopMargin * inchToPt,
                leading: layout.evenLeftMargin * inchToPt,
                bottom: layout.evenBottomMargin * inchToPt,
                trailing: evenRight,
            ),
            twosided: layout.twosided,
        )
    }
}

/// Per-edge margins in points. Mirrors `SwiftUI.EdgeInsets` shape but
/// is kept Foundation-only so the type is usable in code paths that
/// don't import SwiftUI.
public struct PageMargins: Sendable, Equatable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(
        top: CGFloat,
        leading: CGFloat,
        bottom: CGFloat,
        trailing: CGFloat,
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(uniform: CGFloat) {
        self.init(
            top: uniform,
            leading: uniform,
            bottom: uniform,
            trailing: uniform,
        )
    }
}
