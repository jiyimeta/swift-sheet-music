#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// Codec for `OMRPageLabels` (types in `OMRLabelTypes.swift`): decode,
    /// canonical (deterministic, sorted, round-trip-exact) encode, and the
    /// `WalkedContent` → labels conversion used by the export harness.
    enum OMRLabelSchema {
        static let schemaVersion = 1

        static func decode(_ data: Data) throws -> OMRPageLabels {
            try JSONDecoder().decode(OMRPageLabels.self, from: data)
        }

        /// Canonical bytes: arrays in canonical order (§9), keys sorted,
        /// pretty-printed so dataset diffs are real diffs. Doubles are
        /// shortest-round-trip (JSONEncoder default) — bit-exact on decode.
        static func encodeCanonical(_ labels: OMRPageLabels) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(canonicallySorted(labels))
        }

        /// Total orders per stream (spec §9): top-down (y DESC), then
        /// left-right (x ASC), then discriminators — reproducible export,
        /// clean dataset diffs.
        static func canonicallySorted(_ labels: OMRPageLabels) -> OMRPageLabels {
            var out = labels
            // NB: Swift synthesizes tuple `<` only up to 6 elements, so
            // the glyph key (7 components incl. the 4 bbox values) is
            // compared in two stages.
            out.glyphs.sort { a, b in
                let ka = (-a.originPt[1], a.originPt[0], a.className)
                let kb = (-b.originPt[1], b.originPt[0], b.className)
                if ka != kb { return ka < kb }
                let ba = a.bboxPt ?? []
                let bb = b.bboxPt ?? []
                if ba.count != bb.count { return ba.count < bb.count }
                for (x, y) in zip(ba, bb) where x != y {
                    return x < y
                }
                return false
            }
            out.paths.sort {
                (-$0.rectPt[1], $0.rectPt[0], $0.kind, $0.rectPt[2], $0.rectPt[3], $0.lineWidthPt)
                    < (-$1.rectPt[1], $1.rectPt[0], $1.kind, $1.rectPt[2], $1.rectPt[3], $1.lineWidthPt)
            }
            out.beams.sort {
                ($0.x0, -$0.topIntercept, $0.x1, $0.topSlope)
                    < ($1.x0, -$1.topIntercept, $1.x1, $1.topSlope)
            }
            out.curves.sort {
                (-$0.leftPt[1], $0.leftPt[0], $0.rightPt[0], $0.rightPt[1])
                    < (-$1.leftPt[1], $1.leftPt[0], $1.rightPt[0], $1.rightPt[1])
            }
            out.texts.sort {
                (-$0.originPt[1], $0.originPt[0], $0.text, $0.fontName)
                    < (-$1.originPt[1], $1.originPt[0], $1.text, $1.fontName)
            }
            return out
        }

        /// Convert one page of a front-end's WalkedContent to labels.
        /// `inkBBox` supplies the detected-ink box per glyph (Task 5's
        /// outline machinery on the export path; `{ _ in nil }` in unit
        /// tests and for reserved classes). Split into per-stream helpers
        /// below to stay under the 60-line function-body lint cap.
        static func pageLabels(
            walked: WalkedContent, pageIndex: Int, pageSize: CGSize,
            dpi: Int, imageFile: String,
            inkBBox: (ClassifiedGlyph) -> CGRect?,
        ) -> OMRPageLabels {
            let (glyphs, census) = glyphLabels(walked.glyphs, pageIndex: pageIndex, inkBBox: inkBBox)
            let (paths, beams) = pathLabels(walked.paths, pageIndex: pageIndex)
            let curves = curveLabels(walked.curves, pageIndex: pageIndex)
            let texts = textLabels(walked.texts, pageIndex: pageIndex)

            return canonicallySorted(OMRPageLabels(
                schema: schemaVersion,
                page: OMRPageLabels.Page(
                    index: pageIndex,
                    widthPt: Double(pageSize.width),
                    heightPt: Double(pageSize.height),
                ),
                image: OMRPageLabels.Image(
                    file: imageFile, dpi: dpi,
                    labelTransform: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                ),
                glyphs: glyphs, paths: paths, beams: beams,
                curves: curves, texts: texts,
                census: OMRPageLabels.Census(
                    glyphsByClass: census,
                    texts: texts.count,
                ),
            ))
        }

        /// Glyph stream + the full-vocabulary census (every detector class
        /// present with a count, zero included).
        private static func glyphLabels(
            _ source: [ClassifiedGlyph], pageIndex: Int,
            inkBBox: (ClassifiedGlyph) -> CGRect?,
        ) -> (glyphs: [OMRPageLabels.Glyph], census: [String: Int]) {
            var glyphs: [OMRPageLabels.Glyph] = []
            var census: [String: Int] = [:]
            for name in OMRLabelClassNames.detectorVocabulary {
                census[name] = 0
            }
            for g in source where g.geometry.pageIndex == pageIndex {
                let name = OMRLabelClassNames.className(for: g.semantic)
                census[name, default: 0] += 1
                let box = inkBBox(g).map {
                    [Double($0.minX), Double($0.minY), Double($0.maxX), Double($0.maxY)]
                }
                glyphs.append(OMRPageLabels.Glyph(
                    className: name,
                    bboxPt: box,
                    originPt: [Double(g.geometry.origin.x), Double(g.geometry.origin.y)],
                    advancePt: Double(g.geometry.advance),
                    renderedSizePt: Double(g.geometry.renderedSize),
                    fontSizePt: Double(g.geometry.fontSize),
                ))
            }
            return (glyphs, census)
        }

        /// Path stream, with `.beam` segments split off into the beam
        /// stream (only when a fitted quad is present; a quad-less beam
        /// stays a plain `.beam`-kind path).
        private static func pathLabels(
            _ source: [PathSegment], pageIndex: Int,
        ) -> (paths: [OMRPageLabels.Path], beams: [OMRPageLabels.Beam]) {
            var paths: [OMRPageLabels.Path] = []
            var beams: [OMRPageLabels.Beam] = []
            for p in source where p.pageIndex == pageIndex {
                let rect = [
                    Double(p.rect.minX), Double(p.rect.minY),
                    Double(p.rect.maxX), Double(p.rect.maxY),
                ]
                if p.kind == .beam, let q = p.quad {
                    beams.append(OMRPageLabels.Beam(
                        rectPt: rect, lineWidthPt: Double(p.lineWidth),
                        x0: Double(q.xRange.lowerBound), x1: Double(q.xRange.upperBound),
                        topSlope: Double(q.topSlope), topIntercept: Double(q.topIntercept),
                        botSlope: Double(q.botSlope), botIntercept: Double(q.botIntercept),
                    ))
                } else {
                    paths.append(OMRPageLabels.Path(
                        kind: kindName(p.kind), rectPt: rect,
                        lineWidthPt: Double(p.lineWidth),
                    ))
                }
            }
            return (paths, beams)
        }

        private static func curveLabels(
            _ source: [CurveArc], pageIndex: Int,
        ) -> [OMRPageLabels.Curve] {
            source.filter { $0.pageIndex == pageIndex }.map {
                OMRPageLabels.Curve(
                    bboxPt: [
                        Double($0.bbox.minX), Double($0.bbox.minY),
                        Double($0.bbox.maxX), Double($0.bbox.maxY),
                    ],
                    leftPt: [Double($0.leftPoint.x), Double($0.leftPoint.y)],
                    rightPt: [Double($0.rightPoint.x), Double($0.rightPoint.y)],
                )
            }
        }

        private static func textLabels(
            _ source: [TextGlyph], pageIndex: Int,
        ) -> [OMRPageLabels.Text] {
            source.filter { $0.pageIndex == pageIndex }.map {
                OMRPageLabels.Text(
                    text: $0.text, fontName: $0.fontName,
                    fontSizeTf: Double($0.fontSize),
                    renderedSizePt: Double($0.renderedSize),
                    originPt: [Double($0.origin.x), Double($0.origin.y)],
                )
            }
        }

        private static func kindName(_ kind: PathSegment.Kind) -> String {
            switch kind {
            case .horizontal: "horizontal"
            case .vertical: "vertical"
            case .rectangle: "rectangle"
            case .beam: "beam"
            }
        }
    }
#endif
