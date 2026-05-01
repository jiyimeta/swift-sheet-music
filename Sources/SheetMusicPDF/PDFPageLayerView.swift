#if os(macOS)
    import AppKit
    import CoreText
    import QuartzCore
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicUI
    import SwiftUI

    /// CALayer-based page view for the on-screen PDF preview. Each
    /// system layer comes straight from `ScoreLayerBuilder` (the same
    /// vector-CAShapeLayer pipeline that keeps horizontal mode crisp
    /// during pinch-zoom), and title texts are rendered as glyph
    /// CGPaths inside CAShapeLayers — no `CATextLayer` rasterisation,
    /// so AppKit's `NSScrollView.allowsMagnification` re-renders
    /// everything at the new contents scale and the result stays sharp
    /// at any zoom level.
    ///
    /// The Canvas-backed `PDFPageView` is still used for the actual
    /// PDF export (it integrates cleanly with `ImageRenderer` →
    /// `CGPDFContext`); this view is the on-screen counterpart.
    @available(macOS 15.0, *)
    public struct PDFPageLayerView: NSViewRepresentable {
        public let systems: [LayoutSystem]
        public let pageStartY: CGFloat
        public let titleFrame: LayoutTitleFrame?
        public let metrics: StaffMetrics
        public let pageSize: CGSize
        public let margins: PageMargins

        public init(
            systems: [LayoutSystem],
            pageStartY: CGFloat,
            titleFrame: LayoutTitleFrame? = nil,
            metrics: StaffMetrics,
            pageSize: CGSize,
            margins: PageMargins
        ) {
            self.systems = systems
            self.pageStartY = pageStartY
            self.titleFrame = titleFrame
            self.metrics = metrics
            self.pageSize = pageSize
            self.margins = margins
        }

        public func makeNSView(context: Context) -> _PDFPageLayerHostView {
            let view = _PDFPageLayerHostView(frame: NSRect(
                origin: .zero, size: pageSize
            ))
            view.configure(
                systems: systems, pageStartY: pageStartY,
                titleFrame: titleFrame, metrics: metrics,
                pageSize: pageSize, margins: margins
            )
            return view
        }

        public func updateNSView(
            _ nsView: _PDFPageLayerHostView, context: Context
        ) {
            nsView.configure(
                systems: systems, pageStartY: pageStartY,
                titleFrame: titleFrame, metrics: metrics,
                pageSize: pageSize, margins: margins
            )
        }
    }

    @available(macOS 15.0, *)
    public final class _PDFPageLayerHostView: NSView {
        // Identity of the configuration we last applied. Body re-evals
        // during scroll / live magnify must NOT rebuild the layer tree
        // unless an actual input changed.
        private var lastSignature: ConfigSignature?

        override public init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = CGColor(gray: 1, alpha: 1)
            layer?.masksToBounds = true
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) { fatalError() }

        fileprivate func configure(
            systems: [LayoutSystem],
            pageStartY: CGFloat,
            titleFrame: LayoutTitleFrame?,
            metrics: StaffMetrics,
            pageSize: CGSize,
            margins: PageMargins
        ) {
            let signature = ConfigSignature(
                systemCount: systems.count,
                firstSystemId: systems.first.map { ObjectIdentifier(
                    $0.measures as AnyObject)
                },
                pageStartY: pageStartY,
                titleHash: titleFrame?.texts.map(\.text)
                    .joined(separator: "|"),
                pageSize: pageSize,
                margins: margins,
                staffSize: metrics.staffHeight
            )
            if signature == lastSignature { return }
            lastSignature = signature

            if frame.size != pageSize {
                setFrameSize(pageSize)
            }

            guard let host = layer else { return }
            host.sublayers?.forEach { $0.removeFromSuperlayer() }

            // Title text — vector glyph paths so re-rasterisation at
            // higher zoom stays sharp.
            if let titleFrame {
                for entry in titleFrame.texts {
                    if let textLayer = makeTitleTextLayer(
                        entry: entry,
                        pageSize: pageSize, margins: margins
                    ) {
                        host.addSublayer(textLayer)
                    }
                }
            }

            // Systems — reuse the proven ScoreLayerBuilder output.
            for system in systems {
                let systemLayer = SheetMusicUI
                    .ScoreLayerBuilder.buildSystem(
                        system, metrics: metrics
                    )
                // The system layer is built in the platform-native Y
                // (Y-up on macOS, post-`flipForPlatform`). Place its
                // bottom-left so its top sits at the right page Y.
                let topYUp = pageSize.height - margins.top
                    - (system.origin.y - pageStartY)
                systemLayer.frame.origin = CGPoint(
                    x: margins.leading + system.origin.x,
                    y: topYUp - (system.size.height + 1)
                )
                host.addSublayer(systemLayer)
            }
        }
    }

    private struct ConfigSignature: Equatable {
        let systemCount: Int
        let firstSystemId: ObjectIdentifier?
        let pageStartY: CGFloat
        let titleHash: String?
        let pageSize: CGSize
        let margins: PageMargins
        let staffSize: CGFloat
    }

    // MARK: - Title text glyph paths

    @available(macOS 15.0, iOS 16.0, *)
    private func makeTitleTextLayer(
        entry: LayoutFrameText,
        pageSize: CGSize,
        margins: PageMargins
    ) -> CAShapeLayer? {
        // MuseScore's title-block defaults are all `FontStyle::Normal`
        // (no bold / italic) — see `engraving/style/styledef.cpp`.
        let font = systemTextFont(
            size: entry.fontSize, italic: false, bold: false
        )
        guard let path = textPath(entry.text, font: font) else {
            return nil
        }
        let bbox = path.boundingBoxOfPath
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let totalHeight = ascent + descent

        // Path is in baseline-relative coords (x along baseline,
        // y above baseline = positive). For the entry's anchor, we
        // figure out:
        //   * `anchorX` — page-coord X for the text's left edge
        //   * `topPageDown` — page-coord Y (Y-down) of the text's
        //     visible top edge (= ascent above baseline)
        var anchorX: CGFloat = entry.position.x + margins.leading
        switch entry.anchor {
        case .top, .bottom:
            anchorX -= bbox.width / 2
        case .topLeading, .bottomLeading:
            anchorX -= bbox.minX
        case .topTrailing, .bottomTrailing:
            anchorX -= bbox.minX + bbox.width
        }
        let topPageDown: CGFloat
        switch entry.anchor {
        case .topLeading, .top, .topTrailing:
            // Anchor is the visible TOP edge of the text → entry's
            // y already names the top.
            topPageDown = margins.top + entry.position.y
        case .bottomLeading, .bottom, .bottomTrailing:
            // Anchor is the visible BOTTOM edge → text's top sits
            // `totalHeight` above it.
            topPageDown = margins.top + entry.position.y - totalHeight
        }

        // Build the path in Y-down doc coords first (so it lines up
        // with how LayoutEngine positions things), then `flipForPage`
        // mirrors the whole shape into the layer's Y-up coord system.
        var compose = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1,
            tx: anchorX,
            ty: topPageDown + ascent
        )
        guard let down = path.copy(using: &compose) else { return nil }

        var flip = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1, tx: 0, ty: pageSize.height
        )
        guard let up = down.copy(using: &flip) else { return nil }

        let layer = CAShapeLayer()
        layer.path = up
        layer.fillColor = CGColor(gray: 0, alpha: 1)
        _ = descent // referenced for clarity in the comment above
        return layer
    }

    @available(macOS 15.0, iOS 16.0, *)
    private func textPath(_ text: String, font: CTFont) -> CGPath? {
        let attr = NSAttributedString(
            string: text, attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attr)
        let composite = CGMutablePath()
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else {
            return nil
        }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            let range = CFRange(location: 0, length: count)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)
            let runFont: CTFont
            if let attrs = CTRunGetAttributes(run) as? [String: Any],
               let runFontValue = attrs[
                   kCTFontAttributeName as String
               ]
            {
                runFont = unsafeBitCast(
                    runFontValue as AnyObject, to: CTFont.self
                )
            } else {
                runFont = font
            }
            for i in 0 ..< count {
                var t = CGAffineTransform(
                    translationX: positions[i].x,
                    y: positions[i].y
                )
                if let gPath = CTFontCreatePathForGlyph(
                    runFont, glyphs[i], &t
                ) {
                    composite.addPath(gPath)
                }
            }
        }
        return composite.isEmpty ? nil : composite
    }

    @available(macOS 15.0, iOS 16.0, *)
    private func systemTextFont(
        size: CGFloat, italic: Bool, bold: Bool
    ) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if italic { traits.insert(.italicTrait) }
        if bold { traits.insert(.boldTrait) }
        let baseDescriptor = CTFontDescriptorCreateWithNameAndSize(
            "Helvetica" as CFString, size
        )
        if traits.isEmpty {
            return CTFontCreateWithFontDescriptor(
                baseDescriptor, size, nil
            )
        }
        if let traitDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
            baseDescriptor, traits, traits
        ) {
            return CTFontCreateWithFontDescriptor(
                traitDescriptor, size, nil
            )
        }
        return CTFontCreateWithFontDescriptor(baseDescriptor, size, nil)
    }
#endif
