#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// The portable half of the P3d detector: everything except one tile's
/// forward pass.
///
/// normalize → tile → `OMRTileClassifier.run` → decode → merge → map back
/// through the normalization scale and the deskew transform into page points.
struct OMRGlyphDetector: OMRGlyphDetecting {
    /// One classified glyph together with the heatmap score that produced
    /// it — the one number `ClassifiedGlyph` itself does not carry.
    struct ScoredGlyph {
        let glyph: ClassifiedGlyph
        let score: Double
    }

    private let classifier: any OMRTileClassifier
    /// Sees every page's glyphs WITH their scores, after decode + merge and
    /// before they enter `WalkedContent`. A measurement tap only: the
    /// product path passes `nil` and the harness reads a class's confidence
    /// where the importer sees only "present at τ or not". It cannot change
    /// what the detector returns.
    private let observer: (@Sendable (_ pageIndex: Int, _ glyphs: [ScoredGlyph]) -> Void)?
    private var manifest: OMRModelManifest {
        classifier.manifest
    }

    init(
        classifier: any OMRTileClassifier,
        observer: (@Sendable (_ pageIndex: Int, _ glyphs: [ScoredGlyph]) -> Void)? = nil,
    ) throws {
        try classifier.manifest.validate()
        self.classifier = classifier
        self.observer = observer
    }

    func glyphs(
        pageIndex: Int, analysis: RasterPageAnalysis,
        diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?,
    ) throws -> [ClassifiedGlyph] {
        // A page with no staff yields no glyphs, exactly as it yields no
        // paths — there is no staff space to normalize against.
        guard analysis.staffSpacingPx > 0, let deskewed = analysis.deskewed else {
            diagnostics?(PDFImportDiagnostic(
                severity: .warning, location: "page \(pageIndex)",
                message: "OMR: no staff detected on this page; no symbols read from it",
            ))
            return []
        }
        guard let normalized = OMRPrepNormalize.normalize(
            deskewed, staffSpacingPx: analysis.staffSpacingPx,
            targetStaffSpacePx: manifest.staffSpacePx,
        ) else {
            diagnostics?(PDFImportDiagnostic(
                severity: .warning, location: "page \(pageIndex)",
                message: "OMR: cannot normalize a staff spacing of "
                    + "\(analysis.staffSpacingPx)px to the model's \(manifest.staffSpacePx)px",
            ))
            return []
        }
        let detections = try tiles(over: normalized.bitmap)
        if detections.isEmpty {
            diagnostics?(PDFImportDiagnostic(
                severity: .warning, location: "page \(pageIndex)",
                message: "OMR: the detector found no symbols at threshold \(manifest.threshold)",
            ))
        }
        let scored = try detections.map {
            try ScoredGlyph(
                glyph: classify($0, pageIndex: pageIndex, analysis: analysis, scale: normalized.scale),
                score: $0.score,
            )
        }
        // The tap sees everything the decode produced, siblings included:
        // that is the measurement. What leaves is one clef per position.
        observer?(pageIndex, scored)
        return Self.oneClefPerPosition(
            scored, detections: detections,
            isClef: detections.map { manifest.classes[$0.classIndex].hasPrefix("clef") },
            radiusPx: manifest.nmsRadiusSp * manifest.staffSpacePx,
        ).map(\.glyph)
    }

    /// A position holds one clef. The decode's NMS is per class, so a clef
    /// and its octave sibling — `clefF` and `clefF8va` on the same cell,
    /// which is how a real render's split confidence comes out — both
    /// survive it when both clear τ, and the importer's `readClef` then
    /// takes whichever the glyph order puts first. It has no score to
    /// prefer one by; this pass does. Highest score first, a clef within
    /// `radiusPx` (the merge's own dedupe radius, in normalized pixels) of
    /// a kept clef is dropped. Non-clef classes pass through untouched, in
    /// their original order.
    static func oneClefPerPosition(
        _ scored: [ScoredGlyph], detections: [OMRDetectorDecode.Detection], isClef: [Bool],
        radiusPx: Double,
    ) -> [ScoredGlyph] {
        precondition(scored.count == detections.count && isClef.count == detections.count)
        var kept: [Int] = [] // indices of clefs kept, highest score first
        var dropped = Set<Int>()
        for i in scored.indices.filter({ isClef[$0] }).sorted(by: { scored[$0].score > scored[$1].score }) {
            let center = detections[i].centerPx
            let shadowed = kept.contains { j in
                hypot(detections[j].centerPx.x - center.x, detections[j].centerPx.y - center.y) <= radiusPx
            }
            if shadowed { dropped.insert(i) } else { kept.append(i) }
        }
        return scored.indices.filter { !dropped.contains($0) }.map { scored[$0] }
    }

    /// Runs every tile of `bitmap` through the classifier and merges the
    /// per-tile detections into one page-space list. Detections come back
    /// from `decode` in the TILE's local pixel space;
    /// `OMRDetectorDecode.merge` translates them to page space.
    ///
    /// Internal rather than private so the unit tests can drive tiling and
    /// head-shape validation without constructing a page analysis.
    func tiles(over bitmap: GrayBitmap) throws -> [OMRDetectorDecode.Detection] {
        let xs = OMRTiling.origins(extent: bitmap.width, tile: manifest.tile, overlap: manifest.overlap)
        let ys = OMRTiling.origins(extent: bitmap.height, tile: manifest.tile, overlap: manifest.overlap)
        var perTile: [(origin: CGPoint, detections: [OMRDetectorDecode.Detection])] = []
        for oy in ys {
            for ox in xs {
                let heads = try classifier.run(tile: tile(from: bitmap, originX: ox, originY: oy))
                let channels = heads.heatmap.count / max(1, heads.height * heads.width)
                guard channels == manifest.classes.count else {
                    throw SheetMusicError.malformedScore(ScoreFault(
                        code: "omr.detector",
                        message: "OMR detector: heatmap has \(channels) channels, manifest "
                            + "lists \(manifest.classes.count) classes",
                    ))
                }
                perTile.append((
                    origin: CGPoint(x: ox, y: oy),
                    detections: OMRDetectorDecode.decode(
                        heatmap: heads.heatmap, offset: heads.offset, geom: heads.geom,
                        classes: channels, width: heads.width, height: heads.height,
                        stride: manifest.stride, staffSpacePx: manifest.staffSpacePx,
                        threshold: manifest.threshold, topK: manifest.topK,
                    ),
                ))
            }
        }
        return OMRDetectorDecode.merge(
            perTile, pageWidth: bitmap.width, pageHeight: bitmap.height,
            tile: manifest.tile, overlap: manifest.overlap,
            nmsRadiusPx: manifest.nmsRadiusSp * manifest.staffSpacePx,
        )
    }

    /// One tile as normalized `[Float]`, row-major: `manifest.tile`² pixels,
    /// normalized `(byte / 255 - mean) / std`. Pages narrower/shorter than one
    /// tile are zero-padded on the right/bottom rather than resized, which is
    /// the only case `OMRTiling.origins` lets a tile extend past the bitmap.
    ///
    /// PINNED ARITHMETIC — see the plan's Task 5. The pad is a literal `0.0`
    /// in NORMALIZED space (written first, before the crop loop), and the
    /// normalization is computed in `Double` and narrowed once. Both mirror
    /// `Training/model/dataset.py::_load_tile_image`; a drift in either is a
    /// silent numeric divergence from the trained model.
    private func tile(from bitmap: GrayBitmap, originX: Int, originY: Int) -> [Float] {
        let tile = manifest.tile
        var values = [Float](repeating: 0, count: tile * tile)
        let maxX = min(tile, bitmap.width - originX)
        let maxY = min(tile, bitmap.height - originY)
        guard maxX > 0, maxY > 0 else { return values }
        for y in 0 ..< maxY {
            for x in 0 ..< maxX {
                let raw = Double(bitmap[originX + x, originY + y]) / 255.0
                values[y * tile + x] = Float((raw - manifest.mean) / manifest.std)
            }
        }
        return values
    }

    /// Maps one normalized-page-space detection into a `ClassifiedGlyph` in
    /// PDF page points: divide by the normalization scale to reach deskewed
    /// pixels, then `PageTransform.point` to reach page points. `semantic`
    /// returning `nil` here is a programming error `OMRModelManifest.validate`
    /// already excludes at load time, so it throws rather than skipping the
    /// glyph.
    private func classify(
        _ detection: OMRDetectorDecode.Detection, pageIndex: Int,
        analysis: RasterPageAnalysis, scale: Double,
    ) throws -> ClassifiedGlyph {
        let className = manifest.classes[detection.classIndex]
        guard let semantic = OMRGlyphVocabulary.semantic(forClassName: className) else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "omr.detector",
                message: "OMR detector: no semantic for class \(className) — "
                    + "validate() should have caught this at load time",
            ))
        }
        let deskewedX = Double(detection.originPx.x) / scale
        let deskewedY = Double(detection.originPx.y) / scale
        let origin = analysis.transform.point(x: deskewedX, y: deskewedY)
        let perPixel = 72.0 / analysis.transform.dpi
        return ClassifiedGlyph(
            geometry: GlyphGeometry(
                origin: origin,
                advance: CGFloat(Double(detection.advancePx) / scale * perPixel),
                renderedSize: CGFloat(Double(detection.renderedSizePx) / scale * perPixel),
                pageIndex: pageIndex,
                fontSize: 0,
            ),
            semantic: semantic,
        )
    }
}
