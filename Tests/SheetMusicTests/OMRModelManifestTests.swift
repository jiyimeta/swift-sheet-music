#if !os(Android) && !os(WASI)
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

        /// A class list whose COUNT disagrees with the frozen vocabulary — as
        /// opposed to `aReorderedClassListIsRejectedByIndexNotJustCount`'s
        /// same-length, differing-index case — is the other branch of
        /// `checkVocabulary` and needs its own coverage: a bare "N classes does
        /// not match M classes" message is the only signal for this branch, and
        /// nothing else here exercises it.
        @Test func anExtraClassMakesTheListTooLongAndIsRejected() {
            let manifest = OMRModelManifest(
                classes: OMRGlyphVocabulary.trainable + ["noteheadTriangle"],
                staffSpacePx: 12, tile: 384, overlap: 64, stride: 4,
                mean: 0, std: 1, threshold: 0.3, topK: 300, nmsRadiusSp: 0.5,
                decodeDefaultsMeasured: false, checkpoint: "x",
            )
            #expect(throws: (any Error).self) { try manifest.validate() }
        }

        @Test func aShortClassListIsRejected() {
            let manifest = OMRModelManifest(
                classes: Array(OMRGlyphVocabulary.trainable.dropLast()),
                staffSpacePx: 12, tile: 384, overlap: 64, stride: 4,
                mean: 0, std: 1, threshold: 0.3, topK: 300, nmsRadiusSp: 0.5,
                decodeDefaultsMeasured: false, checkpoint: "x",
            )
            #expect(throws: (any Error).self) { try manifest.validate() }
        }

        /// Every field `checkNumerics` guards, ported from the front-end
        /// adapter's own numerics tests (pre-Task-7) now that the check itself
        /// lives here. Each guards a value that decodes fine as JSON but is
        /// semantically nonsense — see `checkNumerics`'s own doc comment for
        /// why each one specifically reads as a clean, silent failure
        /// downstream rather than a crash.
        private static func sampleManifest(
            staffSpacePx: Double = 12, tile: Int = 384, overlap: Int = 64, stride: Int = 4,
            std: Double = 1, threshold: Double = 0.3, topK: Int = 300, nmsRadiusSp: Double = 0.5,
        ) -> OMRModelManifest {
            OMRModelManifest(
                classes: OMRGlyphVocabulary.trainable, staffSpacePx: staffSpacePx,
                tile: tile, overlap: overlap, stride: stride, mean: 0, std: std,
                threshold: threshold, topK: topK, nmsRadiusSp: nmsRadiusSp,
                decodeDefaultsMeasured: false, checkpoint: "x",
            )
        }

        @Test func aFullyValidManifestDoesNotThrow() throws {
            try Self.sampleManifest().validate()
        }

        @Test func aZeroTileIsRejected() {
            #expect(throws: (any Error).self) { try Self.sampleManifest(tile: 0).validate() }
        }

        @Test func aZeroStrideIsRejected() {
            #expect(throws: (any Error).self) { try Self.sampleManifest(stride: 0).validate() }
        }

        @Test func aZeroTopKIsRejected() {
            #expect(throws: (any Error).self) { try Self.sampleManifest(topK: 0).validate() }
        }

        /// `std: 0` decodes fine but divides by zero in `OMRGlyphDetector.tile`'s
        /// `(raw - mean) / std`, turning every tile's input — and so the
        /// classifier's output — into NaN. That reads exactly like the
        /// `staff_space_px: 0` failure `semanticallyNonsenseNumbersAreRejected`
        /// already guards: a clean-looking empty sweep with no diagnostic
        /// anywhere.
        @Test func aZeroStdIsRejected() {
            #expect(throws: (any Error).self) { try Self.sampleManifest(std: 0).validate() }
        }

        /// A negative `overlap` does not fail outright (`OMRTiling.origins`'s
        /// step clamps to `max(1, tile - overlap)`) — it silently opens a gap
        /// between adjacent tiles' pixel windows that `OMRTiling.coreRange`'s
        /// midpoint partition has no way to notice, so pixels in the gap are
        /// never run through the model by any tile and vanish from every
        /// detection.
        @Test func aNegativeOverlapIsRejected() {
            #expect(throws: (any Error).self) { try Self.sampleManifest(overlap: -1).validate() }
        }

        /// The upper bound `checkNumerics` added beyond the pre-Task-7 checks:
        /// `overlap >= tile` degenerates `OMRTiling.origins`'s step to 1 pixel
        /// (`max(1, tile - overlap)` floors at 1), which is not a silent
        /// correctness bug the way a gap is, but is a pathological,
        /// almost-certainly-a-typo configuration worth refusing at load time
        /// rather than discovering as a sweep that never finishes.
        @Test func anOverlapEqualToTileIsRejected() {
            #expect(throws: (any Error).self) { try Self.sampleManifest(tile: 100, overlap: 100).validate() }
        }

        /// `threshold`'s lower bound is currently `> 0` (exactly 0 is
        /// rejected), stricter than the `>= 0` the decode's own doc comment
        /// (`OMRDetectorDecode.decode`) argues is sufficient for its peak scan
        /// to stay exact. `> 0` is a safe superset of that requirement (it
        /// implies `>= 0`), so decode correctness does not depend on which
        /// bound `validate()` uses — this test asserts the ACTUAL, current
        /// behavior so the two do not silently drift apart again.
        @Test func aZeroThresholdIsRejected() {
            #expect(throws: (any Error).self) { try Self.sampleManifest(threshold: 0).validate() }
        }
    }
#endif
