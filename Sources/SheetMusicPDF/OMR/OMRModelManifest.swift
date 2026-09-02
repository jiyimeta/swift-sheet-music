import Foundation
import SheetMusicCore

/// `model.json` as written by `Training/model/export.py`.
///
/// Public, with public members, deliberately: this struct IS the contract
/// between the exporter and this reader, and `OMRTileClassifier` cannot be
/// implemented from another module without it. That freezes the export format
/// as API — accepted, because the class list is already frozen by `validate()`.
///
/// Keys the exporter writes for provenance only (`commit`, `prep_root`,
/// `seed`, `training_config_hash`) have no property here; `JSONDecoder`
/// ignores any key with no match, so they pass through unread.
public struct OMRModelManifest: Decodable, Sendable {
    public let classes: [String]
    public let staffSpacePx: Double
    public let tile: Int
    public let overlap: Int
    public let stride: Int
    public let mean: Double
    public let std: Double
    public let threshold: Double
    public let topK: Int
    public let nmsRadiusSp: Double
    /// Whether the three decode constants above were swept or guessed.
    public let decodeDefaultsMeasured: Bool
    /// `--checkpoint` as passed to `export.py`: literally `"random"` for the
    /// untrained floor model, a path otherwise.
    public let checkpoint: String

    enum CodingKeys: String, CodingKey {
        case classes
        case staffSpacePx = "staff_space_px"
        case tile, overlap, stride, mean, std, threshold
        case topK = "top_k"
        case nmsRadiusSp = "nms_radius_sp"
        case decodeDefaultsMeasured = "decode_defaults_measured"
        case checkpoint
    }

    public init(
        classes: [String], staffSpacePx: Double, tile: Int, overlap: Int, stride: Int,
        mean: Double, std: Double, threshold: Double, topK: Int, nmsRadiusSp: Double,
        decodeDefaultsMeasured: Bool, checkpoint: String,
    ) {
        self.classes = classes
        self.staffSpacePx = staffSpacePx
        self.tile = tile
        self.overlap = overlap
        self.stride = stride
        self.mean = mean
        self.std = std
        self.threshold = threshold
        self.topK = topK
        self.nmsRadiusSp = nmsRadiusSp
        self.decodeDefaultsMeasured = decodeDefaultsMeasured
        self.checkpoint = checkpoint
    }

    /// Both load-time gates. Call before the first `run(tile:)`.
    public func validate() throws {
        try checkVocabulary()
        try checkNumerics()
    }

    private func checkVocabulary() throws {
        let expected = OMRGlyphVocabulary.trainable
        guard classes != expected else { return }
        if classes.count != expected.count {
            throw fault(
                "model class list (\(classes.count) classes) does not match the frozen "
                    + "trainable vocabulary (\(expected.count) classes)",
            )
        }
        let index = classes.indices.first { classes[$0] != expected[$0] } ?? 0
        throw fault(
            "model class list disagrees with the frozen trainable vocabulary at index "
                + "\(index): model has \"\(classes[index])\", expected \"\(expected[index])\"",
        )
    }

    private func checkNumerics() throws {
        guard staffSpacePx > 0 else { throw fault("staff_space_px must be > 0, got \(staffSpacePx)") }
        guard tile > 0 else { throw fault("tile must be > 0, got \(tile)") }
        guard overlap >= 0, overlap < tile else { throw fault("overlap \(overlap) must be in 0..<\(tile)") }
        guard stride > 0 else { throw fault("stride must be > 0, got \(stride)") }
        guard std != 0 else { throw fault("std must be non-zero") }
        guard threshold > 0, threshold < 1 else { throw fault("threshold must be in (0,1), got \(threshold)") }
        guard topK > 0 else { throw fault("top_k must be > 0, got \(topK)") }
        guard nmsRadiusSp > 0 else { throw fault("nms_radius_sp must be > 0, got \(nmsRadiusSp)") }
    }

    private func fault(_ message: String) -> any Error {
        SheetMusicError.malformedScore(ScoreFault(code: "omr.detector", message: "OMR detector: \(message)"))
    }
}
