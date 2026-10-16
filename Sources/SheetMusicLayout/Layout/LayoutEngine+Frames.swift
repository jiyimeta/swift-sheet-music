#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension LayoutEngine {
    /// Lays out a `<VBox>` or `<TBox>` that sits between systems; `nil` for the other block kinds (an HBox is
    /// horizontal room inside a system, an opaque frame has no layout). `originY` and `beforeMeasureIndex` are left
    /// at 0 for the stream placer to fill in.
    static func layoutFrame(
        _ block: ScoreBlock,
        style: ScoreStyle,
        metrics: StaffMetrics,
        docWidth: CGFloat,
        pictures: [String: Data],
    ) -> LayoutFrame? {
        switch block {
        case let .verticalFrame(source):
            return layoutVerticalFrame(source, style: style, metrics: metrics, docWidth: docWidth, pictures: pictures)
        case let .textFrame(source):
            return layoutTextFrame(source, style: style, docWidth: docWidth)
        case .horizontalFrame, .opaqueFrame:
            return nil
        }
    }

    /// A `<VBox>` after the title. Its texts come from the title builder; its height follows MuseScore's autosize rule
    /// (`box.cpp:624-627`): `max(10 sp, content)` unless `<boxAutoSize>` is 0, in which case `<height>` as written
    /// (ours still grows if a top-anchored text would be clipped, the title builder's guard). Pictures are fitted
    /// into the box as written, then an autosized box is widened to the lowest picture bottom.
    private static func layoutVerticalFrame(
        _ source: ScoreFrame,
        style: ScoreStyle,
        metrics: StaffMetrics,
        docWidth: CGFloat,
        pictures: [String: Data],
    ) -> LayoutFrame {
        let sp = metrics.sp
        let images = layoutImages(
            of: source, pictures: pictures, docWidth: docWidth, fitHeight: source.heightSp * sp, sp: sp,
        )
        var sized = source
        if source.autoSize ?? true {
            let imageBottom = images.map(\.rect.maxY).max() ?? 0
            sized.heightSp = max(10, imageBottom / sp)
        }
        let content = buildTitleFrame(source: sized, style: style, metrics: metrics, docWidth: docWidth)
        return LayoutFrame(
            kind: .vertical,
            beforeMeasureIndex: 0,
            originY: 0,
            height: content.height,
            content: content,
            images: images,
            pageBreakAfter: source.pageBreakAfter,
        )
    }

    /// A `<TBox>`: its text at `(leftMargin, topMargin)` anchored by the text's `<align>` horizontally and always at
    /// the top, `<size>` honored, height = the text's measured height plus the top and bottom margins
    /// (`boxlayout.cpp:337-362`). `<boxAutoSize>` and `<height>` do not matter to a TBox.
    private static func layoutTextFrame(_ source: TextFrame, style: ScoreStyle, docWidth: CGFloat) -> LayoutFrame {
        let mmToPt: CGFloat = 72.0 / 25.4
        let margins = source.margins
        var texts: [LayoutFrameText] = []
        var textHeight: CGFloat
        if let text = source.text {
            let entry = textFrameEntry(text, style: style, margins: margins, docWidth: docWidth)
            texts = [entry.text]
            textHeight = entry.height
        } else {
            textHeight = ascent(ofTitleFaceAt: 10)
        }
        let height = margins.top * mmToPt + textHeight + margins.bottom * mmToPt
        return LayoutFrame(
            kind: .text,
            beforeMeasureIndex: 0,
            originY: 0,
            height: height,
            content: LayoutTitleFrame(height: height, texts: texts),
            images: [],
            pageBreakAfter: source.pageBreakAfter,
        )
    }

    private static func textFrameEntry(
        _ text: FrameText, style: ScoreStyle, margins: FrameMargins, docWidth: CGFloat,
    ) -> (text: LayoutFrameText, height: CGFloat) {
        let mmToPt: CGFloat = 72.0 / 25.4
        let defaultSize = titleBlockLayout(for: text.style, idx: 0, style: style, override: nil, mmToPt: mmToPt)
        let fontSize = CGFloat(text.fontSize ?? Double(defaultSize.fontSize))
        let horizontal = text.align?.horizontal ?? .left
        let x: CGFloat = switch horizontal {
        case .left: margins.left * mmToPt
        case .center: (margins.left * mmToPt + docWidth - margins.right * mmToPt) / 2
        case .right: docWidth - margins.right * mmToPt
        }
        let rich = text.richText.map { titleRichText($0, style: text.style, fontSize: fontSize) }
        let entry = LayoutFrameText(
            text: text.text,
            style: text.style,
            position: CGPoint(x: x, y: margins.top * mmToPt),
            fontSize: fontSize,
            anchor: anchor(for: TextAlign(horizontal: horizontal, vertical: .top)),
            richText: rich,
        )
        let height: CGFloat
        if let lines = rich?.lines {
            height = lines.reduce(0) { $0 + $1.ascent + $1.descent }
        } else if text.text.isEmpty {
            height = ascent(ofTitleFaceAt: fontSize)
        } else {
            let lineCount = text.text.split(separator: "\n", omittingEmptySubsequences: false).count
            height = CGFloat(lineCount) * LayoutTitleFrame.lineHeight(fontSize: fontSize)
        }
        return (entry, height)
    }

    /// The ascent of the title-block face at `size` points (`boxlayout.cpp:350-355`: an empty text still takes it).
    private static func ascent(ofTitleFaceAt size: CGFloat) -> CGFloat {
        let provider = FontMetrics.provider
        return provider.ascent(font: provider.renderingTextFont(LayoutTitleFrame.font(size: size)))
    }
}
