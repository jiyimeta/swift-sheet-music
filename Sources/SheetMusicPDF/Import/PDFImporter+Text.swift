import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

extension PDFImporter {
    /// Extract a title frame from page-1 top-band text glyphs.
    ///
    /// Algorithm:
    ///  1. Filter `texts` to glyphs on page 0 in the top 25% of the
    ///     page (PDF coordinates are y-up, so top is `y > 0.75 *
    ///     height`). Empty / whitespace-only glyphs are dropped.
    ///  2. The largest font size becomes the `.title`.
    ///  3. The first remaining glyph whose origin is past 60% of the
    ///     page width becomes the `.composer` (right-aligned heuristic).
    ///  4. The next-largest remaining glyph becomes the `.subtitle`.
    ///  5. If `options.useMetadataAsFallback` is true, any role still
    ///     missing is filled from `PDFDocument.documentAttributes`
    ///     (Title / Author / Subject keys).
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
                && $0.origin.y > pageSize.height * 0.75
                && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        var frameTexts: [FrameText] = []
        if !topBand.isEmpty {
            collectTitleBlock(
                from: topBand, pageWidth: pageSize.width,
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

    private static func collectTitleBlock(
        from topBand: [TextGlyph],
        pageWidth: CGFloat,
        into frameTexts: inout [FrameText],
    ) {
        let sorted = topBand.sorted { $0.fontSize > $1.fontSize }
        if let title = sorted.first {
            frameTexts.append(FrameText(style: .title, text: title.text))
        }
        let titleText = frameTexts.first?.text
        if let composer = topBand.first(where: {
            $0.origin.x > pageWidth * 0.6 && $0.text != titleText
        }) {
            frameTexts.append(
                FrameText(style: .composer, text: composer.text),
            )
        }
        let used = Set(frameTexts.map(\.text))
        if let subtitle = sorted.dropFirst().first(where: {
            !used.contains($0.text)
        }) {
            frameTexts.append(
                FrameText(style: .subtitle, text: subtitle.text),
            )
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
