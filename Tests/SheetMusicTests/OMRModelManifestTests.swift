import Foundation
@testable import SheetMusicPDF
import Testing

struct OMRModelManifestTests {
    /// The exact key spellings `Training/model/export.py` writes.
    static let goodJSON: String = {
        // swiftlint:disable:next force_try force_unwrapping
        let classesJSON = String(data: try! JSONEncoder().encode(OMRGlyphVocabulary.trainable), encoding: .utf8)!
        return """
        {"classes": \(classesJSON),
         "staff_space_px": 12.0, "tile": 384, "overlap": 64, "stride": 4,
         "mean": 0.0, "std": 1.0, "threshold": 0.3, "top_k": 300,
         "nms_radius_sp": 0.5, "decode_defaults_measured": false,
         "checkpoint": "/tmp/checkpoint_last.pt"}
        """
    }()

    @Test func decodesTheExporterSnakeCaseKeys() throws {
        let manifest = try JSONDecoder().decode(
            OMRModelManifest.self, from: Data(Self.goodJSON.utf8),
        )
        #expect(manifest.staffSpacePx == 12.0)
        #expect(manifest.topK == 300)
        #expect(manifest.nmsRadiusSp == 0.5)
        #expect(manifest.decodeDefaultsMeasured == false)
    }

    @Test func aReorderedClassListIsRejectedByIndexNotJustCount() throws {
        var classes = OMRGlyphVocabulary.trainable
        classes.swapAt(3, 4)
        let manifest = OMRModelManifest(
            classes: classes, staffSpacePx: 12, tile: 384, overlap: 64, stride: 4,
            mean: 0, std: 1, threshold: 0.3, topK: 300, nmsRadiusSp: 0.5,
            decodeDefaultsMeasured: false, checkpoint: "x",
        )
        // Assert the MESSAGE, not merely that something threw. Both lists are
        // 62 long, so a count-only check would pass this manifest — and the
        // test name would be a lie. The message must name the first differing
        // index and both class names there, which is the only form that is
        // actionable when 62 near-identical strings disagree at one spot.
        var message = ""
        #expect(throws: (any Error).self) {
            do { try manifest.validate() } catch {
                message = "\(error)"
                throw error
            }
        }
        #expect(message.contains("index 3"), "message did not name the differing index: \(message)")
        #expect(message.contains("noteheadHalf"), "message did not name the model's class: \(message)")
        #expect(message.contains("noteheadBlack"), "message did not name the expected class: \(message)")
    }

    @Test func semanticallyNonsenseNumbersAreRejected() {
        let manifest = OMRModelManifest(
            classes: OMRGlyphVocabulary.trainable, staffSpacePx: 0, tile: 384,
            overlap: 64, stride: 4, mean: 0, std: 1, threshold: 0.3, topK: 300,
            nmsRadiusSp: 0.5, decodeDefaultsMeasured: false, checkpoint: "x",
        )
        // staffSpacePx == 0 makes normalize() return nil for every page, so
        // the detector reports a clean-looking zero recall instead of an error.
        #expect(throws: (any Error).self) { try manifest.validate() }
    }
}
