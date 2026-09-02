#if !os(Android) && !os(WASI)
    import Foundation
    import SheetMusicOMRModel
    @testable import SheetMusicPDF

    /// Test-side adapter over the product detector.
    ///
    /// Everything the P3d CenterNet-style detector used to do here now lives
    /// in `OMRGlyphDetector` (normalize → tile → classify → decode → merge →
    /// map back to page points) and `CoreMLTileClassifier` (the one platform-
    /// specific step, one tile's forward pass). This type is a thin seam that
    /// keeps the eval harness's call sites unchanged and holds the
    /// `OMR_DECODE_*` sweep overrides, which deliberately do NOT exist in
    /// `Sources`: a product path must not read them, and their
    /// `fatalError`-on-unparseable behavior (right for a sweep that must
    /// never report the baseline under a swept label, wrong for a library)
    /// is resolved by living here.
    struct OMRDetectorFrontEnd: OMRGlyphDetecting {
        private let detector: OMRGlyphDetector
        let manifest: OMRModelManifest

        /// A classifier that reports a manifest with the swept constants
        /// substituted, forwarding inference to the real one. This wrapper is
        /// the only route to the decode constants after the migration —
        /// `manifest` is get-only on the protocol.
        private struct Overridden: OMRTileClassifier, @unchecked Sendable {
            let manifest: OMRModelManifest
            let base: any OMRTileClassifier
            func run(tile: [Float]) throws -> OMRHeadOutputs {
                try base.run(tile: tile)
            }
        }

        /// `modelRoot: nil` uses the model bundled with `SheetMusicOMRModel`
        /// — the G1 gate's whole point is that the bundled model is now the
        /// source of truth, not a downloaded directory.
        init(modelRoot: URL?) async throws {
            let base: any OMRTileClassifier = if let modelRoot {
                try await CoreMLTileClassifier(modelRoot: modelRoot)
            } else {
                try CoreMLTileClassifier()
            }
            manifest = Self.applyDecodeOverrides(to: base.manifest)
            detector = try OMRGlyphDetector(
                classifier: Overridden(manifest: manifest, base: base),
            )
        }

        func glyphs(
            pageIndex: Int, analysis: RasterPageAnalysis,
            diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?,
        ) throws -> [ClassifiedGlyph] {
            try detector.glyphs(pageIndex: pageIndex, analysis: analysis, diagnostics: diagnostics)
        }

        /// Overrides the three DECODE constants from the environment, so
        /// spec §11's sweep is a shell loop over one exported model instead
        /// of a re-export per setting:
        ///
        ///     OMR_DECODE_THRESHOLD  detection threshold τ
        ///     OMR_DECODE_TOP_K      per-tile top-K
        ///     OMR_DECODE_NMS_SP     merge NMS radius, in staff spaces
        ///
        /// Only these three. `staff_space_px` (S) and `tile` (T) are baked
        /// into the trained weights and the exported graph — a model
        /// trained at S=12 does not become an S=16 model by being told so,
        /// it becomes a wrong one. Sweeping those means re-exporting the
        /// prep root and retraining, which is why the spec separates them.
        ///
        /// An unparseable value THROWS (via `fatalError`) rather than
        /// falling back to the manifest: a swept run that silently ignored
        /// its own parameter would report the baseline's numbers under the
        /// swept setting's label, which is the one outcome a sweep cannot
        /// survive. The rebuilt manifest goes back through `validate()`
        /// (called by `OMRGlyphDetector.init`), so a nonsense τ is rejected
        /// the same way a nonsense manifest is.
        ///
        /// `decodeDefaultsMeasured` is deliberately NOT set by an override —
        /// it records whether the values in the MANIFEST were swept, and an
        /// override is by definition not yet that.
        static func applyDecodeOverrides(
            to manifest: OMRModelManifest,
            environment: [String: String] = ProcessInfo.processInfo.environment,
        ) -> OMRModelManifest {
            var threshold = manifest.threshold
            var topK = manifest.topK
            var nmsRadiusSp = manifest.nmsRadiusSp
            var applied: [String] = []
            if let raw = environment["OMR_DECODE_THRESHOLD"] {
                threshold = Self.parse(raw, name: "OMR_DECODE_THRESHOLD")
                applied.append("threshold=\(threshold)")
            }
            if let raw = environment["OMR_DECODE_TOP_K"] {
                topK = Int(Self.parse(raw, name: "OMR_DECODE_TOP_K"))
                applied.append("topK=\(topK)")
            }
            if let raw = environment["OMR_DECODE_NMS_SP"] {
                nmsRadiusSp = Self.parse(raw, name: "OMR_DECODE_NMS_SP")
                applied.append("nmsRadiusSp=\(nmsRadiusSp)")
            }
            if !applied.isEmpty {
                print("[detect-override] \(applied.joined(separator: " "))")
            }
            // Fields are `let` on `OMRModelManifest`, so an override rebuilds
            // through the public memberwise init rather than mutating.
            return OMRModelManifest(
                classes: manifest.classes, staffSpacePx: manifest.staffSpacePx,
                tile: manifest.tile, overlap: manifest.overlap, stride: manifest.stride,
                mean: manifest.mean, std: manifest.std, threshold: threshold, topK: topK,
                nmsRadiusSp: nmsRadiusSp, decodeDefaultsMeasured: manifest.decodeDefaultsMeasured,
                checkpoint: manifest.checkpoint,
            )
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
    }
#endif
