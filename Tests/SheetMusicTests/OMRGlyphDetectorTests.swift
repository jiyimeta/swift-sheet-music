import Foundation
@testable import SheetMusicPDF
import Testing

struct OMRGlyphDetectorTests {
    /// A classifier that records the tiles it is handed and returns empty heads.
    final class RecordingClassifier: OMRTileClassifier, @unchecked Sendable {
        let manifest: OMRModelManifest
        var tiles: [[Float]] = []

        init(manifest: OMRModelManifest) {
            self.manifest = manifest
        }

        func run(tile: [Float]) throws -> OMRHeadOutputs {
            tiles.append(tile)
            let h = manifest.tile / manifest.stride
            return OMRHeadOutputs(
                heatmap: [Float](repeating: 0, count: manifest.classes.count * h * h),
                offset: [Float](repeating: 0, count: 2 * h * h),
                geom: [Float](repeating: 0, count: 4 * h * h),
                height: h, width: h,
            )
        }
    }

    /// The `diagnostics` parameter is `@Sendable`, so a plain captured `var`
    /// is a Swift 6 concurrency error. Same sink shape the rest of the
    /// importer's diagnostics tests use.
    final class MessageSink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []

        func append(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            items.append(message)
        }

        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    static func manifest(mean: Double = 0, std: Double = 1) -> OMRModelManifest {
        OMRModelManifest(
            classes: OMRGlyphVocabulary.trainable, staffSpacePx: 12, tile: 384,
            overlap: 64, stride: 4, mean: mean, std: std, threshold: 0.3, topK: 300,
            nmsRadiusSp: 0.5, decodeDefaultsMeasured: false, checkpoint: "test",
        )
    }

    /// The pad is 0.0 in NORMALIZED space, not in pixel space. With
    /// mean=0.5/std=1 a white pixel normalizes to +0.5 and the pad stays 0.0 —
    /// if padding were applied before normalization it would read -0.5.
    @Test func tilePaddingIsZeroInNormalizedSpace() throws {
        let manifest = Self.manifest(mean: 0.5, std: 1)
        let classifier = RecordingClassifier(manifest: manifest)
        let detector = try OMRGlyphDetector(classifier: classifier)
        // A page smaller than one tile: everything past the image is pad.
        let bitmap = GrayBitmap(
            pixels: [UInt8](repeating: 255, count: 10 * 10), width: 10, height: 10, dpi: 300,
        )
        _ = try detector.tiles(over: bitmap)
        let tile = try #require(classifier.tiles.first)
        #expect(tile[0] == Float(0.5), "in-image white must normalize to (1.0 - 0.5)/1")
        #expect(tile[11] == Float(0), "out-of-image must be a literal 0.0")
    }

    /// staffSpacingPx == 0 means no staff was found: there is no scale to
    /// normalize against, so the page yields no glyphs AND says so.
    @Test func aPageWithNoStaffYieldsNoGlyphsAndDiagnoses() throws {
        let classifier = RecordingClassifier(manifest: Self.manifest())
        let detector = try OMRGlyphDetector(classifier: classifier)
        let analysis = RasterPageAnalysis(
            paths: [], transform: PageTransform(dpi: 300, widthPx: 100, heightPx: 100, deskewDegrees: 0),
            staffSpacingPt: 0, deskewDegrees: 0,
            deskewed: GrayBitmap(pixels: [UInt8](repeating: 255, count: 100), width: 10, height: 10, dpi: 300),
        )
        let messages = MessageSink()
        let glyphs = try detector.glyphs(
            pageIndex: 0, analysis: analysis, diagnostics: { messages.append($0.message) },
        )
        #expect(glyphs.isEmpty)
        #expect(messages.snapshot.contains { $0.contains("no staff") })
    }

    /// A manifest whose heatmap channel count disagrees with its class list is
    /// the silent-wrong-score case arriving through a different door.
    @Test func aHeatmapWithTheWrongChannelCountThrows() throws {
        final class WrongShape: OMRTileClassifier, @unchecked Sendable {
            let manifest = OMRGlyphDetectorTests.manifest()
            func run(tile _: [Float]) throws -> OMRHeadOutputs {
                let h = manifest.tile / manifest.stride
                return OMRHeadOutputs(
                    heatmap: [Float](repeating: 0, count: 7 * h * h), // not 62
                    offset: [Float](repeating: 0, count: 2 * h * h),
                    geom: [Float](repeating: 0, count: 4 * h * h),
                    height: h, width: h,
                )
            }
        }
        let detector = try OMRGlyphDetector(classifier: WrongShape())
        let bitmap = GrayBitmap(
            pixels: [UInt8](repeating: 255, count: 400 * 400), width: 400, height: 400, dpi: 300,
        )
        #expect(throws: (any Error).self) { try detector.tiles(over: bitmap) }
    }
}
