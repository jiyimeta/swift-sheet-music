#if !os(Android)
    import CoreGraphics
    import CoreML
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// Runs the P3d CenterNet-style detector (`model.mlpackage`, written by
    /// `Training/model/export.py`) over a normalized page and emits
    /// `ClassifiedGlyph` in page space — the raster front-end's actual
    /// symbol classifier, as opposed to `OMROracleFrontEnd`'s ground-truth
    /// stand-in.
    ///
    /// Pipeline per page (design §3.1): normalize the deskewed bitmap to
    /// the model's canonical staff space (`OMRPrepNormalize`), cut it into
    /// tiles (`OMRTiling`), run each tile through Core ML, decode each
    /// tile's three heads (`OMRDetectorDecode.decode`), merge tiles into
    /// one page-space list (`OMRDetectorDecode.merge`), then map each
    /// merged detection back through the normalization scale and the
    /// deskew transform into PDF page points.
    final class OMRDetectorFrontEnd: OMRGlyphDetecting {
        /// The `model.json` fields this side reads. Extra keys the Python
        /// exporter writes for provenance (`commit`, `prep_root`, `seed`,
        /// `training_config_hash`) are not decoded here — `JSONDecoder`
        /// ignores any key with no matching property, so they simply pass
        /// through unread. `decode_defaults_measured` and `checkpoint` ARE
        /// decoded: the eval harness's summary line prints both (so a
        /// saved sweep log states whether the decode constants it used
        /// were actually swept, not guessed) and
        /// `OMRDetectorFrontEndModelTests` reads `checkpoint` to tell the
        /// untrained floor model (`--checkpoint random`) apart from a
        /// trained one.
        struct Manifest: Decodable {
            var classes: [String]
            var staffSpacePx: Double
            var tile: Int
            var overlap: Int
            var stride: Int
            var mean: Double
            var std: Double
            var threshold: Double
            var topK: Int
            var nmsRadiusSp: Double
            var decodeDefaultsMeasured: Bool
            var checkpoint: String

            enum CodingKeys: String, CodingKey {
                case classes
                case staffSpacePx = "staff_space_px"
                case tile, overlap, stride, mean, std, threshold
                case topK = "top_k"
                case nmsRadiusSp = "nms_radius_sp"
                case decodeDefaultsMeasured = "decode_defaults_measured"
                case checkpoint
            }
        }

        private let model: MLModel
        private let manifest: Manifest

        /// Decode-time constants a caller (the eval harness's summary
        /// line) needs to print alongside its measured numbers, so a
        /// saved log is self-describing about which run produced it.
        var threshold: Double {
            manifest.threshold
        }

        var topK: Int {
            manifest.topK
        }

        var nmsRadiusSp: Double {
            manifest.nmsRadiusSp
        }

        var decodeDefaultsMeasured: Bool {
            manifest.decodeDefaultsMeasured
        }

        /// `--checkpoint` as passed to `Training/model/export.py`:
        /// literally `"random"` for the untrained P3d-G1 floor model, a
        /// checkpoint path otherwise.
        var checkpoint: String {
            manifest.checkpoint
        }

        init(modelRoot: URL) async throws {
            let manifestData = try Data(contentsOf: modelRoot.appendingPathComponent("model.json"))
            let decoded = try JSONDecoder().decode(Manifest.self, from: manifestData)
            let manifest = Self.applyDecodeOverrides(to: decoded)
            try Self.checkVocabulary(manifest.classes)
            try Self.checkNumerics(manifest)

            let packageURL = modelRoot.appendingPathComponent("model.mlpackage")
            let compiledURL = try await MLModel.compileModel(at: packageURL)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: compiledURL, configuration: configuration)
            self.manifest = manifest
        }

        /// Overrides the three DECODE constants from the environment, so
        /// spec §11's sweep is a shell loop over one exported model
        /// instead of a re-export per setting:
        ///
        ///     OMR_DECODE_THRESHOLD  detection threshold τ
        ///     OMR_DECODE_TOP_K      per-tile top-K
        ///     OMR_DECODE_NMS_SP     merge NMS radius, in staff spaces
        ///
        /// Only these three. `staff_space_px` (S) and `tile` (T) are
        /// baked into the trained weights and the exported graph — a
        /// model trained at S=12 does not become an S=16 model by being
        /// told so, it becomes a wrong one. Sweeping those means
        /// re-exporting the prep root and retraining, which is why the
        /// spec separates them.
        ///
        /// An unparseable value THROWS rather than falling back to the
        /// manifest: a swept run that silently ignored its own parameter
        /// would report the baseline's numbers under the swept setting's
        /// label, which is the one outcome a sweep cannot survive.
        /// `checkNumerics` then applies to the overridden values, so a
        /// nonsense τ is rejected the same way a nonsense manifest is.
        ///
        /// `decode_defaults_measured` is deliberately NOT set by an
        /// override — it records whether the values in the MANIFEST were
        /// swept, and an override is by definition not yet that.
        static func applyDecodeOverrides(
            to manifest: Manifest,
            environment: [String: String] = ProcessInfo.processInfo.environment,
        ) -> Manifest {
            var out = manifest
            var applied: [String] = []
            if let raw = environment["OMR_DECODE_THRESHOLD"] {
                out.threshold = Self.parse(raw, name: "OMR_DECODE_THRESHOLD")
                applied.append("threshold=\(out.threshold)")
            }
            if let raw = environment["OMR_DECODE_TOP_K"] {
                out.topK = Int(Self.parse(raw, name: "OMR_DECODE_TOP_K"))
                applied.append("topK=\(out.topK)")
            }
            if let raw = environment["OMR_DECODE_NMS_SP"] {
                out.nmsRadiusSp = Self.parse(raw, name: "OMR_DECODE_NMS_SP")
                applied.append("nmsRadiusSp=\(out.nmsRadiusSp)")
            }
            if !applied.isEmpty {
                print("[detect-override] \(applied.joined(separator: " "))")
            }
            return out
        }

        private static func parse(_ raw: String, name: String) -> Double {
            guard let value = Double(raw) else {
                // A sweep that quietly ignores its own parameter is worse
                // than one that dies, so this is fatal rather than a
                // fallback to the manifest value.
                fatalError("\(name)=\"\(raw)\" is not a number")
            }
            return value
        }

        /// The gate: throws unless `classes` is EXACTLY
        /// `OMRPrepTargets.trainableVocabulary`, in order. A model whose
        /// class 7 means something other than the frozen table's class 7
        /// would otherwise build a plausible-looking score out of the
        /// wrong symbols — no crash, no diagnostic, just a wrong score.
        /// Pure and callable with no model present, which is what makes it
        /// testable without `OMR_MODEL_ROOT`. Names the first differing
        /// index and both class names there — a bare length mismatch
        /// ("62 classes does not match ... 62 classes") is useless for
        /// the load-bearing reorder case, where the two counts are
        /// identical and the only difference is at one index.
        static func checkVocabulary(_ classes: [String]) throws {
            let expected = OMRPrepTargets.trainableVocabulary
            guard classes != expected else { return }
            if classes.count != expected.count {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: model class list (\(classes.count) classes) does not "
                        + "match the frozen trainable vocabulary (\(expected.count) classes)",
                )
            }
            let index = classes.indices.first { classes[$0] != expected[$0] } ?? 0
            throw SheetMusicError.malformedScore(
                reason: "OMR detector: model class list disagrees with the frozen trainable "
                    + "vocabulary at index \(index): model has \"\(classes[index])\", "
                    + "expected \"\(expected[index])\"",
            )
        }

        /// A manifest field that decodes as a syntactically valid number
        /// but is semantically nonsense (`staff_space_px: 0`, `tile: 0`,
        /// `std: 0`, …) does not fail to decode, so `JSONDecoder` alone
        /// lets it through. Left unchecked, `staff_space_px: 0` makes
        /// `OMRPrepNormalize.normalize` return `nil` for every page
        /// (division by the target staff space), so `glyphs(page:
        /// analysis:)` returns `[]` everywhere and the eval harness
        /// reports a clean-looking `recall=0.0000` — indistinguishable
        /// from "the detector genuinely finds nothing" instead of "the
        /// manifest is broken". `std: 0` reaches the same failure by a
        /// different road: `makeInput`'s `(raw - mean) / std` divides by
        /// zero, so every tile's input is NaN and the model's output is
        /// NaN too, again reading as an empty, clean-looking sweep.
        /// `overlap` is checked for sign rather than positivity — see
        /// below. Pure and callable with no model present, same
        /// reasoning as `checkVocabulary`.
        static func checkNumerics(_ manifest: Manifest) throws {
            let positiveChecks: [(name: String, value: Double)] = [
                ("staff_space_px", manifest.staffSpacePx),
                ("tile", Double(manifest.tile)),
                ("stride", Double(manifest.stride)),
                ("top_k", Double(manifest.topK)),
            ]
            for check in positiveChecks where check.value <= 0 {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: manifest field \"\(check.name)\" must be positive, "
                        + "got \(check.value)",
                )
            }
            // `OMRTiling.origins`' step is `max(1, tile - overlap)`, so a
            // negative overlap does not fail outright — it silently
            // widens the step past `tile`, opening a real gap between
            // adjacent tile pixel WINDOWS. `OMRTiling.coreRange` still
            // partitions the page by the midpoint between tile origins
            // with no awareness of that gap, so it hands a tile's merge
            // step a "core" region that extends past pixels that tile's
            // window ever covered — pixels in the gap are never run
            // through the model by ANY tile, and silently vanish from
            // every detection, not merely a slower or redundant sweep.
            guard manifest.overlap >= 0 else {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: manifest field \"overlap\" must be non-negative, "
                        + "got \(manifest.overlap)",
                )
            }
            guard manifest.std != 0 else {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: manifest field \"std\" must not be zero, "
                        + "got \(manifest.std)",
                )
            }
            // The heatmap head is a sigmoid, so its cells live in [0, 1]
            // and a negative threshold selects EVERY cell of every class
            // channel — 62 x 96 x 96 per tile. It is also the one input
            // `OMRDetectorDecode.decode`'s peak scan requires to be
            // non-negative: the scan skips the neighbourhood test for
            // cells at or below the threshold (they can never become
            // candidates), which is exact for a threshold of 0 or more
            // and would silently change the result below zero.
            guard manifest.threshold >= 0, manifest.threshold < 1 else {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: manifest field \"threshold\" must be in [0, 1), "
                        + "got \(manifest.threshold)",
                )
            }
        }

        func glyphs(page: OMRPageLabels, analysis: RasterPageAnalysis) throws -> [ClassifiedGlyph] {
            // A page with no staff yields no glyphs, exactly as it yields
            // no paths — there is no staff space to normalize against.
            guard analysis.staffSpacingPx > 0, let deskewed = analysis.deskewed else { return [] }
            guard let normalized = OMRDetectTiming.shared.measure("detect.normalize", {
                OMRPrepNormalize.normalize(
                    deskewed, staffSpacingPx: analysis.staffSpacingPx,
                    targetStaffSpacePx: manifest.staffSpacePx,
                )
            }) else { return [] }

            let detections = try runTiles(over: normalized.bitmap)
            return try detections.map { detection in
                try classify(detection, page: page, analysis: analysis, scale: normalized.scale)
            }
        }

        /// Runs every tile of `bitmap` through the model and merges the
        /// per-tile detections into one page-space list. Each tile's Core
        /// ML round trip is wrapped in `autoreleasepool` — a sweep in this
        /// repo that skipped this for a per-tile loop consumed 24GB and
        /// took the machine down.
        private func runTiles(over bitmap: GrayBitmap) throws -> [OMRDetectorDecode.Detection] {
            let xs = OMRTiling.origins(extent: bitmap.width, tile: manifest.tile, overlap: manifest.overlap)
            let ys = OMRTiling.origins(extent: bitmap.height, tile: manifest.tile, overlap: manifest.overlap)
            var tiles: [(origin: CGPoint, detections: [OMRDetectorDecode.Detection])] = []
            for oy in ys {
                for ox in xs {
                    try autoreleasepool {
                        let detections = try detect(tileAt: ox, oy, in: bitmap)
                        tiles.append((origin: CGPoint(x: ox, y: oy), detections: detections))
                    }
                }
            }
            return OMRDetectTiming.shared.measure("detect.merge") {
                OMRDetectorDecode.merge(
                    tiles, pageWidth: bitmap.width, pageHeight: bitmap.height,
                    tile: manifest.tile, overlap: manifest.overlap,
                    nmsRadiusPx: manifest.nmsRadiusSp * manifest.staffSpacePx,
                )
            }
        }

        /// One tile's Core ML round trip: build the input tensor, run the
        /// model, decode its three heads. Detections come back in the
        /// TILE's local pixel space; `runTiles` translates them to page
        /// space via `OMRDetectorDecode.merge`.
        private func detect(
            tileAt ox: Int, _ oy: Int, in bitmap: GrayBitmap,
        ) throws -> [OMRDetectorDecode.Detection] {
            let provider = try OMRDetectTiming.shared.measure("detect.makeInput") {
                let input = try makeInput(bitmap, originX: ox, originY: oy)
                return try MLDictionaryFeatureProvider(
                    dictionary: ["image": MLFeatureValue(multiArray: input)],
                )
            }
            let output = try OMRDetectTiming.shared.measure("detect.predict") {
                try model.prediction(from: provider)
            }
            guard let heatmapArray = output.featureValue(for: "heatmap")?.multiArrayValue,
                  let offsetArray = output.featureValue(for: "offset")?.multiArrayValue,
                  let geomArray = output.featureValue(for: "geom")?.multiArrayValue
            else {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: model output is missing heatmap / offset / geom",
                )
            }
            let heatmap = try OMRDetectTiming.shared.measure("detect.flatten") {
                try flatten(heatmapArray)
            }
            guard heatmap.channels == manifest.classes.count else {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: heatmap has \(heatmap.channels) channels, manifest "
                        + "lists \(manifest.classes.count) classes",
                )
            }
            let offset = try OMRDetectTiming.shared.measure("detect.flatten") { try flatten(offsetArray) }
            let geom = try OMRDetectTiming.shared.measure("detect.flatten") { try flatten(geomArray) }
            return OMRDetectTiming.shared.measure("detect.decode") {
                OMRDetectorDecode.decode(
                    heatmap: heatmap.values, offset: offset.values, geom: geom.values,
                    classes: heatmap.channels, width: heatmap.width, height: heatmap.height,
                    stride: manifest.stride, staffSpacePx: manifest.staffSpacePx,
                    threshold: manifest.threshold, topK: manifest.topK,
                )
            }
        }

        /// Maps one normalized-page-space detection into a `ClassifiedGlyph`
        /// in PDF page points (task-14 brief step 5): divide by the
        /// normalization scale to reach deskewed pixels, then
        /// `PageTransform.point` to reach page points. `semantic` returning
        /// `nil` here is a programming error `checkVocabulary` already
        /// excludes at load time, so it throws rather than skipping the
        /// glyph.
        private func classify(
            _ detection: OMRDetectorDecode.Detection, page: OMRPageLabels,
            analysis: RasterPageAnalysis, scale: Double,
        ) throws -> ClassifiedGlyph {
            let className = manifest.classes[detection.classIndex]
            guard let semantic = OMRLabelClassNames.semantic(forClassName: className) else {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: no semantic for class \(className) — "
                        + "checkVocabulary should have caught this at load time",
                )
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
                    pageIndex: page.page.index,
                    fontSize: 0,
                ),
                semantic: semantic,
            )
        }

        /// Builds the model's `image` input for the tile at
        /// `(originX, originY)`: `manifest.tile`² float32 pixels,
        /// normalized `(byte / 255 - mean) / std`. Pages narrower/shorter
        /// than one tile are zero-padded on the right/bottom rather than
        /// resized — mirroring `dataset._load_tile_image` — which is the
        /// only case `OMRTiling.origins` lets a tile extend past the
        /// bitmap.
        private func makeInput(_ bitmap: GrayBitmap, originX: Int, originY: Int) throws -> MLMultiArray {
            let tile = manifest.tile
            let array = try MLMultiArray(
                shape: [1, 1, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float32,
            )
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: tile * tile)
            pointer.update(repeating: 0, count: tile * tile)
            let maxX = min(tile, bitmap.width - originX)
            let maxY = min(tile, bitmap.height - originY)
            guard maxX > 0, maxY > 0 else { return array }
            for y in 0 ..< maxY {
                for x in 0 ..< maxX {
                    let raw = Double(bitmap[originX + x, originY + y]) / 255.0
                    pointer[y * tile + x] = Float((raw - manifest.mean) / manifest.std)
                }
            }
            return array
        }

        private struct FlatArray {
            var values: [Float]
            var channels: Int
            var height: Int
            var width: Int
        }

        /// Flattens a Core ML output into CHW-order `[Float]`, the layout
        /// `OMRDetectorDecode.decode` expects, walking `strides` rather
        /// than assuming the array is contiguous — Core ML is free to lay
        /// a multi-array out however the selected compute unit prefers.
        private func flatten(_ array: MLMultiArray) throws -> FlatArray {
            guard array.dataType == .float32 else {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: expected a float32 model output, got \(array.dataType)",
                )
            }
            let shape = array.shape.map(\.intValue)
            let strides = array.strides.map(\.intValue)
            guard shape.count >= 3 else {
                throw SheetMusicError.malformedScore(
                    reason: "OMR detector: model output has rank \(shape.count), expected at least 3",
                )
            }
            let rank = shape.count
            let channels = shape[rank - 3], height = shape[rank - 2], width = shape[rank - 1]
            let cStride = strides[rank - 3], hStride = strides[rank - 2], wStride = strides[rank - 1]
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            var values = [Float](repeating: 0, count: channels * height * width)
            var i = 0
            for c in 0 ..< channels {
                for h in 0 ..< height {
                    for w in 0 ..< width {
                        values[i] = pointer[c * cStride + h * hStride + w * wStride]
                        i += 1
                    }
                }
            }
            return FlatArray(values: values, channels: channels, height: height, width: width)
        }
    }
#endif
