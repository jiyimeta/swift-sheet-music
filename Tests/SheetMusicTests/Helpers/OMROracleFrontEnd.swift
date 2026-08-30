#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// The oracle front-end (spec §4.3): a raster front-end with a
    /// PERFECT detector. Reads page labels, materializes the exact
    /// `buildScore` input tuple minus document attributes. Callers pass
    /// `documentAttributes: nil` to `buildScore` (spec §4.1).
    enum OMROracleFrontEnd {
        struct Replay {
            var walked: WalkedContent
            var pageSizes: [Int: CGSize]
            var pageCount: Int
        }

        static func replay(pages: [OMRPageLabels]) throws -> Replay {
            var walked = WalkedContent(glyphs: [], texts: [], paths: [], curves: [])
            var pageSizes: [Int: CGSize] = [:]
            var maxIndex = -1
            for page in pages.sorted(by: { $0.page.index < $1.page.index }) {
                let idx = page.page.index
                maxIndex = max(maxIndex, idx)
                pageSizes[idx] = CGSize(width: page.page.widthPt, height: page.page.heightPt)

                try walked.glyphs.append(contentsOf: glyphs(page.glyphs, pageIndex: idx))
                try walked.paths.append(contentsOf: paths(page.paths, pageIndex: idx))
                try walked.paths.append(contentsOf: beamPaths(page.beams, pageIndex: idx))
                try walked.curves.append(contentsOf: curves(page.curves, pageIndex: idx))
                try walked.texts.append(contentsOf: texts(page.texts, pageIndex: idx))
            }
            return Replay(walked: walked, pageSizes: pageSizes, pageCount: maxIndex + 1)
        }

        private static func glyphs(
            _ source: [OMRPageLabels.Glyph], pageIndex: Int,
        ) throws -> [ClassifiedGlyph] {
            try source.map { g in
                guard let semantic = OMRGlyphVocabulary.semantic(forClassName: g.className) else {
                    throw SheetMusicError.malformedScore(ScoreFault(
                        code: "omr.oracle",
                        message: "OMR labels: unknown class \(g.className)",
                    ))
                }
                return try ClassifiedGlyph(
                    geometry: GlyphGeometry(
                        origin: point(g.originPt, what: "glyph origin_pt"),
                        advance: CGFloat(g.advancePt),
                        renderedSize: CGFloat(g.renderedSizePt),
                        pageIndex: pageIndex,
                        fontSize: CGFloat(g.fontSizePt),
                    ),
                    semantic: semantic,
                )
            }
        }

        private static func paths(
            _ source: [OMRPageLabels.Path], pageIndex: Int,
        ) throws -> [PathSegment] {
            try source.map { p in
                try PathSegment(
                    kind: kind(p.kind),
                    rect: rect(p.rectPt, what: "path rect_pt"),
                    lineWidth: CGFloat(p.lineWidthPt),
                    pageIndex: pageIndex,
                    quad: nil,
                )
            }
        }

        private static func beamPaths(
            _ source: [OMRPageLabels.Beam], pageIndex: Int,
        ) throws -> [PathSegment] {
            try source.map { b in
                try PathSegment(
                    kind: .beam,
                    rect: rect(b.rectPt, what: "beam rect_pt"),
                    lineWidth: CGFloat(b.lineWidthPt),
                    pageIndex: pageIndex,
                    quad: BeamQuad(
                        xRange: CGFloat(b.x0) ... CGFloat(max(b.x0, b.x1)),
                        topSlope: CGFloat(b.topSlope),
                        topIntercept: CGFloat(b.topIntercept),
                        botSlope: CGFloat(b.botSlope),
                        botIntercept: CGFloat(b.botIntercept),
                        pageIndex: pageIndex,
                    ),
                )
            }
        }

        private static func curves(
            _ source: [OMRPageLabels.Curve], pageIndex: Int,
        ) throws -> [CurveArc] {
            try source.map { c in
                try CurveArc(
                    bbox: rect(c.bboxPt, what: "curve bbox_pt"),
                    leftPoint: point(c.leftPt, what: "curve left_pt"),
                    rightPoint: point(c.rightPt, what: "curve right_pt"),
                    pageIndex: pageIndex,
                )
            }
        }

        private static func texts(
            _ source: [OMRPageLabels.Text], pageIndex: Int,
        ) throws -> [TextGlyph] {
            try source.map { t in
                try TextGlyph(
                    text: t.text,
                    fontName: t.fontName,
                    fontSize: CGFloat(t.fontSizeTf),
                    renderedSize: CGFloat(t.renderedSizePt),
                    origin: point(t.originPt, what: "text origin_pt"),
                    bbox: .zero, // never populated in production either
                    pageIndex: pageIndex,
                )
            }
        }

        private static func kind(_ name: String) throws -> PathSegment.Kind {
            switch name {
            case "horizontal": return .horizontal
            case "vertical": return .vertical
            case "rectangle": return .rectangle
            case "beam": return .beam
            default:
                throw SheetMusicError.malformedScore(ScoreFault(
                    code: "omr.oracle",
                    message: "OMR labels: unknown path kind \(name)",
                ))
            }
        }

        private static func point(_ a: [Double], what: String) throws -> CGPoint {
            guard a.count == 2 else {
                throw SheetMusicError.malformedScore(ScoreFault(
                    code: "omr.oracle", message: "OMR labels: bad \(what)",
                ))
            }
            return CGPoint(x: a[0], y: a[1])
        }

        private static func rect(_ a: [Double], what: String) throws -> CGRect {
            guard a.count == 4 else {
                throw SheetMusicError.malformedScore(ScoreFault(
                    code: "omr.oracle", message: "OMR labels: bad \(what)",
                ))
            }
            return CGRect(x: a[0], y: a[1], width: a[2] - a[0], height: a[3] - a[1])
        }
    }
#endif
