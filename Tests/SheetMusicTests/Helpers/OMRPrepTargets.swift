#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF

    /// Label glyphs (clean page space, y-up points) → detector targets
    /// (normalized pixels, y-down) — the second half of design §3.1.
    ///
    /// The first half is `OMRHybridFrontEnd.pointMap`, which is reused
    /// rather than rewritten. What is added here is the y-flip into the
    /// front-end's own pixel frame and the normalization scale.
    enum OMRPrepTargets {
        /// Classes that exist in the labels but can never be a detector
        /// target. `stem` and `staff5Lines` are P3b's (design §7.1);
        /// `restOther` discards its duration's parameters, so
        /// `semantic(forClassName:)` returns nil for it by design and a
        /// prediction of that class could not become a `ClassifiedGlyph`;
        /// `unknown*` is outside the frozen vocabulary; and the two
        /// UNREACHABLE rows have no glyph to detect.
        static func isTrainable(_ className: String) -> Bool {
            guard !className.hasPrefix("unknown") else { return false }
            guard !["stem", "staff5Lines", "restOther"].contains(className)
            else { return false }
            guard !unreachable.contains(className) else { return false }
            return OMRLabelClassNames.detectorVocabulary.contains(className)
        }

        static let unreachable: Set = ["fine", "toCoda"]

        /// The 62 trainable classes, in frozen table order. The model's
        /// class index IS this array's index.
        static let trainableVocabulary: [String] =
            OMRLabelClassNames.detectorVocabulary.filter(isTrainable)

        static func glyphs(
            page: OMRPageLabels, transform: PageTransform, scale: Double,
        ) -> (glyphs: [OMRPrepPage.Glyph], droppedNoBBox: Int) {
            let map = OMRHybridFrontEnd.pointMap(page: page, transform: transform)
            let toPixel = { (point: CGPoint) -> [Double] in
                let mapped = map(point)
                let perPoint = transform.dpi / 72.0
                return [
                    Double(mapped.x) * perPoint * scale,
                    (Double(transform.heightPx) - Double(mapped.y) * perPoint) * scale,
                ]
            }
            var out: [OMRPrepPage.Glyph] = []
            var dropped = 0
            for glyph in page.glyphs where isTrainable(glyph.className) {
                guard let box = glyph.bboxPt, box.count == 4 else {
                    dropped += 1
                    continue
                }
                let a = toPixel(CGPoint(x: box[0], y: box[1]))
                let b = toPixel(CGPoint(x: box[2], y: box[3]))
                out.append(OMRPrepPage.Glyph(
                    className: glyph.className,
                    centerPx: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2],
                    originPx: toPixel(CGPoint(
                        x: glyph.originPt[0], y: glyph.originPt[1],
                    )),
                    // Derived from the MAPPED corners (`a`, `b`), not
                    // from `advancePt`/`renderedSizePt` scaled directly
                    // by `dpi/72 * scale` — that shortcut agrees with
                    // the mapped-corner length on a clean page (identity
                    // `labelTransform`), but a degraded page's
                    // `label_transform` carries its own resample scale
                    // (`Training/generate/profiles/scanner.toml`'s
                    // `scale_lo`/`scale_hi`), which `centerPx`/`originPx`
                    // absorb via `map` and this shortcut did not — a
                    // systematic geometry-target error on every glyph of
                    // a degraded page.
                    advancePx: abs(b[0] - a[0]),
                    renderedSizePx: abs(b[1] - a[1]),
                ))
            }
            return (out, dropped)
        }
    }
#endif
