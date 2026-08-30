import Foundation

/// The three heads of one tile's forward pass, flat, CHW, all at the same
/// `(height, width)`. `heatmap` is post-sigmoid per-class probability with
/// `classes` channels, `offset` has 2 and `geom` has 4.
public struct OMRHeadOutputs: Sendable {
    public var heatmap: [Float]
    public var offset: [Float]
    public var geom: [Float]
    public var height: Int
    public var width: Int

    /// REQUIRED: `CoreMLTileClassifier` is in another module, so the
    /// synthesized memberwise init would be internal and unusable there.
    public init(heatmap: [Float], offset: [Float], geom: [Float], height: Int, width: Int) {
        self.heatmap = heatmap
        self.offset = offset
        self.geom = geom
        self.height = height
        self.width = width
    }
}

/// The ONE platform-specific step in the raster front-end: running a tile
/// through the network.
///
/// Everything around it — normalization, tiling, head decoding, tile merging,
/// coordinate mapping — is portable Swift and lives in this module, so a
/// non-Core ML backend reuses all of it and reimplements only this.
public protocol OMRTileClassifier: Sendable {
    /// The manifest the model was exported with. `OMRGlyphDetector` calls
    /// `validate()` on it before first use.
    var manifest: OMRModelManifest { get }

    /// One `tile × tile` grayscale tile, already normalized to
    /// `(value/255 - mean) / std` and row-major. Implementations perform
    /// inference only: no cropping, no normalization, no decoding.
    ///
    /// **The implementation owns an `autoreleasepool` (or equivalent) around
    /// its own work.** A per-tile loop in this repo that skipped one consumed
    /// 24GB and took the machine down; the pool cannot live in the portable
    /// caller because that code also compiles for Android.
    func run(tile: [Float]) throws -> OMRHeadOutputs
}
