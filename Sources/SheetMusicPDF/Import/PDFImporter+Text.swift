#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Extract a title frame from page-1 top-band text glyphs.
    ///
    /// MuseScore's PDF export emits each title / credit character as its
    /// own text glyph (one Tj per char, like music glyphs), so a title
    /// such as "ギブス" arrives as 3 separate `TextGlyph`s. The extractor
    /// first MERGES adjacent glyphs sharing a y-row + font size into a
    /// single run (x-adjacency), then maps runs to roles:
    ///
    ///  1. Filter to page 0, top of the page (PDF y-up, `y > 0.5 ×
    ///     height` — wide enough to also reach a sub-title credit block
    ///     that sits below the masthead). Empty glyphs dropped.
    ///  2. Merge into runs; the largest-font run is `.title`.
    ///  3. The lowest run on the right half (a credit line such as
    ///     "Arranged by …") is `.composer` — claimed *before* the subtitle
    ///     so a lone right-aligned credit isn't first swallowed by the
    ///     position-agnostic subtitle rule.
    ///  4. The next-largest distinct-row run not already used is
    ///     `.subtitle`.
    ///  5. If `options.useMetadataAsFallback` is true, any role still
    ///     missing is filled from `PDFDocument.documentAttributes`.
    ///
    /// Returns `nil` when no candidates are found and metadata is
    /// either disabled or empty.
    static func extractTitleFrame(
        texts: [TextGlyph],
        pageSize: CGSize,
        documentAttributes: [String: Any]?,
        options: PDFImportOptions,
    ) -> ScoreFrame? {
        let topBand = texts.filter {
            $0.pageIndex == 0
                && $0.origin.y > pageSize.height * 0.6
                && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        var frameTexts: [FrameText] = []
        if !topBand.isEmpty {
            let runs = mergeTextRuns(topBand)
            collectTitleBlock(
                from: runs, pageWidth: pageSize.width,
                into: &frameTexts,
            )
        }
        if options.useMetadataAsFallback, let attrs = documentAttributes {
            mergeMetadataFallback(into: &frameTexts, attrs: attrs)
        }
        return frameTexts.isEmpty
            ? nil
            : ScoreFrame(heightSp: 12, texts: frameTexts)
    }

    /// One merged text run: full text plus geometry of its leftmost glyph.
    struct TextRun {
        var text: String
        var x: CGFloat
        var y: CGFloat
        var fontSize: CGFloat
    }

    /// Merge per-character glyphs into runs by y-row + x-adjacency. Two
    /// glyphs join when they share a baseline (|Δy| ≤ 0.3 × fontSize),
    /// the same font size (|Δsize| ≤ 1), and the origin x-step is at or
    /// below `fontSize × 0.45` (above MuseScore's ~0.2 × inter-glyph
    /// title advance, below a column gap). Returns runs sorted top-down,
    /// then left-to-right.
    static func mergeTextRuns(_ glyphs: [TextGlyph]) -> [TextRun] {
        let sorted = glyphs.sorted {
            if abs($0.origin.y - $1.origin.y) > 3 { return $0.origin.y > $1.origin.y }
            return $0.origin.x < $1.origin.x
        }
        var runs: [TextRun] = []
        var curText = ""
        var curX: CGFloat = 0
        var curY: CGFloat = 0
        var curSize: CGFloat = 0
        var prevX: CGFloat?
        for g in sorted {
            let s = g.text.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            let sameRow = abs(g.origin.y - curY) <= max(g.fontSize, curSize) * 0.3
            let sameSize = abs(g.fontSize - curSize) <= 1
            let step = prevX.map { g.origin.x - $0 } ?? .infinity
            let adjacent = step <= g.fontSize * 0.45 && step >= 0
            if curText.isEmpty || !(sameRow && sameSize && adjacent) {
                if !curText.isEmpty {
                    runs.append(TextRun(text: curText, x: curX, y: curY, fontSize: curSize))
                }
                curText = s
                curX = g.origin.x
                curY = g.origin.y
                curSize = g.fontSize
            } else {
                curText += s
            }
            prevX = g.origin.x
        }
        if !curText.isEmpty {
            runs.append(TextRun(text: curText, x: curX, y: curY, fontSize: curSize))
        }
        return runs
    }

    private static func collectTitleBlock(
        from runs: [TextRun],
        pageWidth: CGFloat,
        into frameTexts: inout [FrameText],
    ) {
        guard !runs.isEmpty else { return }
        let byFont = runs.sorted { $0.fontSize > $1.fontSize }
        // Title = largest-font run.
        guard let title = byFont.first else { return }
        frameTexts.append(FrameText(style: .title, text: title.text))
        // Composer = the lowest credit run sitting on the right half, other
        // than the title (e.g. "Arranged by Kiichi" under the masthead).
        // Detected BEFORE the subtitle: composer has a horizontal (right-
        // half) constraint, while the subtitle rule is position-agnostic,
        // so running subtitle first lets it swallow a lone right-aligned
        // credit that is really the composer (regression fixed here).
        let composer = runs
            .filter { $0.text != title.text && $0.x > pageWidth * 0.4 }
            .min { $0.y < $1.y }
        if let composer {
            frameTexts.append(FrameText(style: .composer, text: composer.text))
        }
        // Subtitle = the next-largest run on a DIFFERENT baseline row than
        // the title (so a same-row sibling glyph isn't taken as subtitle)
        // and not already claimed by the composer. Row tolerance is
        // absolute (~6 pt) because the masthead font can be very large,
        // which would otherwise swallow a close credit row.
        let used = Set(frameTexts.map(\.text))
        let subtitle = byFont.dropFirst().first {
            abs($0.y - title.y) > 6 && !used.contains($0.text)
        }
        if let subtitle {
            frameTexts.append(FrameText(style: .subtitle, text: subtitle.text))
        }
    }

    private static func mergeMetadataFallback(
        into frameTexts: inout [FrameText],
        attrs: [String: Any],
    ) {
        let hasTitle = frameTexts.contains { $0.style == .title }
        let hasComposer = frameTexts.contains { $0.style == .composer }
        let hasSubtitle = frameTexts.contains { $0.style == .subtitle }
        if !hasTitle, let v = attrs["Title"] as? String, !v.isEmpty {
            frameTexts.append(FrameText(style: .title, text: v))
        }
        if !hasComposer, let v = attrs["Author"] as? String, !v.isEmpty {
            frameTexts.append(FrameText(style: .composer, text: v))
        }
        if !hasSubtitle, let v = attrs["Subject"] as? String, !v.isEmpty {
            frameTexts.append(FrameText(style: .subtitle, text: v))
        }
    }
}
