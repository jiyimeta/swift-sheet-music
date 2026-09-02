#if !os(Android) && !os(WASI)
    import Foundation
    @testable import SheetMusicPDF

    /// A classifier that reports its base's manifest with the `OMR_DECODE_*`
    /// sweep constants substituted, forwarding inference untouched.
    ///
    /// `OMRDetectorFrontEnd` holds the same wrapper for the synthetic eval;
    /// this one exists so the `.mscz` ground-truth corpus — which builds its
    /// detector from `PDFImportOptions.omrTileClassifier` rather than through
    /// that front-end — can be swept by the same three environment variables.
    ///
    /// Sweeping τ on the corpus answers a question the corpus could not ask
    /// before: a class that is absent at the shipped τ but present at a lower
    /// one is a CONFIDENCE failure (fix: training data / augmentation), while
    /// one still absent at τ→0 is a blind spot in the heatmap (fix: the class
    /// is not learned for this domain at all). Those want opposite work.
    struct OMRDecodeOverriddenClassifier: OMRTileClassifier, @unchecked Sendable {
        let manifest: OMRModelManifest
        let base: any OMRTileClassifier

        init(base: any OMRTileClassifier) {
            self.base = base
            manifest = OMRDetectorFrontEnd.applyDecodeOverrides(to: base.manifest)
        }

        func run(tile: [Float]) throws -> OMRHeadOutputs {
            try base.run(tile: tile)
        }
    }
#endif
