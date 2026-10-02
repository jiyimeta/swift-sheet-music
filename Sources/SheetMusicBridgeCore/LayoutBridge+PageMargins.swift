import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`, clashing with SheetMusicLayout's stub. Anchor
    /// to the Layout definition.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

extension LayoutBridge {
    /// Paper margins around a `.page`-mode page, in millimetres. Every other mode ignores them.
    ///
    /// With margins the page is a sheet of paper, as the Apple page deck and PDF export draw it (`MacPageDeckMetrics`
    /// and `ReaderPrintLayout` in folino): the score is engraved into the page width less `leading` and `trailing`, cut
    /// into pages by the page height less `top` and `bottom`, and each page's commands sit `leading` right of and `top`
    /// below the page's top-left corner. A page can come out wider than the page width — see
    /// `paperWidthMM(for:pageWidthMM:)` — but never taller.
    ///
    /// `.zero` is the edge-to-edge page the Android and web readers draw, unchanged: exactly the page width, the music
    /// from the page's top-left corner, and nothing widened even where the music overflows. The margins are a separate
    /// argument rather than a field of `LayoutOptionsWire`, so neither of those wires changes.
    public struct PageMargins: Sendable, Equatable {
        public var top: Double
        public var leading: Double
        public var bottom: Double
        public var trailing: Double

        public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
            self.top = top
            self.leading = leading
            self.bottom = bottom
            self.trailing = trailing
        }

        /// The edge-to-edge page: what every caller that passes no margins gets, byte for byte as before.
        public static let zero = PageMargins(top: 0, leading: 0, bottom: 0, trailing: 0)
    }
}

extension LayoutBridge {
    /// `pageWidthMM`, or — when `document`'s widest system runs past `lineWidthMM`, the width it was engraved into,
    /// which a single measure wider than the line makes it do — that system's right edge plus `sideMarginsMM`. The
    /// right edge is `origin.x + size.width`, not `document.size.width`, which carries the engine's trailing whitespace
    /// and would widen the page of a score that fits. Compared in points against the very width the engine was
    /// handed, so music that fits the line exactly does not widen the page by the last bit of a millimetre-to-point
    /// round trip, and `pageWidthMM` comes back untouched.
    static func widenedPageWidthMM(
        _ pageWidthMM: Double, fitting document: LayoutDocument, lineWidthMM: Double, sideMarginsMM: Double,
    ) -> Double {
        let musicRightPt = document.systems.map { $0.origin.x + $0.size.width }.max() ?? 0
        let lineWidthPt = CGFloat(lineWidthMM * (72.0 / 25.4))
        guard musicRightPt > lineWidthPt else { return pageWidthMM }
        return max(pageWidthMM, Double(musicRightPt) * (25.4 / 72.0) + sideMarginsMM)
    }
}

extension LayoutBridge.PageMargins {
    /// The width the score is engraved into. Margins that leave no printable width are the caller's error.
    func printableWidthMM(pageWidthMM: Double) -> Double {
        pageWidthMM - leading - trailing
    }

    /// The height pages are cut by. Margins that leave no printable height give no pages (`LayoutPaginator`).
    func printableHeightMM(pageHeightMM: Double) -> Double {
        pageHeightMM - top - bottom
    }

    /// The width every page of `document` is drawn at: `pageWidthMM`, or — when the music came out wider than the
    /// printable width, which a single measure wider than the line can make it — the music's right edge plus both side
    /// margins, so no notehead is drawn off the paper. `.zero` margins never widen (the edge-to-edge page).
    ///
    /// Apple's rule, `MacPageDeckMetrics.pageSize(forDocumentWidth:)` fed by `ReaderPrintLayout.pageSize(for:)`:
    /// `max(paper width, music width + 2 × margin)`, one width for every sheet of the document rather than per sheet,
    /// and the music width taken from the widest system's right edge (`origin.x + size.width`) — not from
    /// `document.size.width`, which carries the engine's trailing whitespace and would widen every page of a score
    /// that fits. The height is never widened.
    func paperWidthMM(for document: LayoutDocument, pageWidthMM: Double) -> Double {
        guard self != .zero else { return pageWidthMM }
        return LayoutBridge.widenedPageWidthMM(
            pageWidthMM, fitting: document, lineWidthMM: printableWidthMM(pageWidthMM: pageWidthMM),
            sideMarginsMM: leading + trailing,
        )
    }

    /// One page's commands and spans as `LayoutBridge.buildCommandsWithSpans` emits them — the music from the page's
    /// top-left corner — moved onto the paper: every command and every span's frame `leading` right and `top` down.
    ///
    /// A pass over the finished commands rather than an offset where the systems are placed, because the title block
    /// is not a system: its texts carry their own document positions (`LayoutTitleFrame`), so moving the systems alone
    /// would leave it in the corner. One translation moves both, and leaves the command ranges as they were.
    func place(
        _ built: (commands: [DrawCommand], spans: [SystemSpan]),
    ) -> (commands: [DrawCommand], spans: [SystemSpan]) {
        guard leading != 0 || top != 0 else { return built }
        let commands = built.commands.map { $0.translated(dx: leading, dy: top) }
        let spans = built.spans.map { span in
            var span = span
            span.frameMM = span.frameMM.offsetBy(dx: leading, dy: top)
            return span
        }
        return (commands, spans)
    }
}

extension DrawCommand {
    /// This command moved `dx` right and `dy` down, in its own millimetres: every position it carries and none of its
    /// sizes.
    ///
    /// Positions: `moveTo` / `lineTo`'s point, `cubicTo`'s two control points and end point, `fillRect`'s origin (not
    /// its `w` / `h`), `glyph` and `text`'s origin (not their size), `stretchedGlyph`'s `rightEdgeX`, `topY` and
    /// `bottomY` (not its `fontSize` or `xScale`), and a non-zero `setRotation`'s pivot. The reset
    /// `setRotation(radians: 0, …)` rotates about no point and is left as emitted, as are the commands that carry no
    /// position — `stroke`'s width, `setDash`'s lengths, `setColor`, `setTextStyle`, `fillPath`. The switch has no
    /// default, so a new command does not compile until it says which of the two it is.
    func translated(dx: Double, dy: Double) -> DrawCommand {
        switch self {
        case let .moveTo(x, y):
            .moveTo(x: x + dx, y: y + dy)
        case let .lineTo(x, y):
            .lineTo(x: x + dx, y: y + dy)
        case let .cubicTo(cx1, cy1, cx2, cy2, x, y):
            .cubicTo(cx1: cx1 + dx, cy1: cy1 + dy, cx2: cx2 + dx, cy2: cy2 + dy, x: x + dx, y: y + dy)
        case let .fillRect(x, y, w, h):
            .fillRect(x: x + dx, y: y + dy, w: w, h: h)
        case let .glyph(codepoint, x, y, size, fontId):
            .glyph(codepoint: codepoint, x: x + dx, y: y + dy, size: size, fontId: fontId)
        case let .text(text, x, y, size, fontId):
            .text(text: text, x: x + dx, y: y + dy, size: size, fontId: fontId)
        case let .stretchedGlyph(codepoint, rightEdgeX, topY, bottomY, fontSize, xScale, fontId):
            .stretchedGlyph(
                codepoint: codepoint, rightEdgeX: rightEdgeX + dx, topY: topY + dy, bottomY: bottomY + dy,
                fontSize: fontSize, xScale: xScale, fontId: fontId,
            )
        case let .setRotation(radians, pivotX, pivotY):
            radians == 0 ? self : .setRotation(radians: radians, pivotX: pivotX + dx, pivotY: pivotY + dy)
        case .stroke, .setColor, .setDash, .setTextStyle, .fillPath:
            self
        }
    }
}

extension DrawRect {
    /// This rectangle moved `dx` right and `dy` down; its size is kept.
    func offsetBy(dx: Double, dy: Double) -> DrawRect {
        DrawRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}
