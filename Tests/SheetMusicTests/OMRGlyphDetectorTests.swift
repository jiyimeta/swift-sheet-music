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

    /// A classifier that plants two peaks in ONE cell, in two different class
    /// channels — the shape of the real-render octave-clef failure, where the
    /// heatmap splits its confidence between `clefF` and `clefF8va` at the
    /// same position.
    final class SiblingPeaksClassifier: OMRTileClassifier, @unchecked Sendable {
        let manifest: OMRModelManifest
        let peaks: [(className: String, score: Float)]

        init(manifest: OMRModelManifest, peaks: [(className: String, score: Float)]) {
            self.manifest = manifest
            self.peaks = peaks
        }

        func run(tile _: [Float]) throws -> OMRHeadOutputs {
            let h = manifest.tile / manifest.stride
            var heatmap = [Float](repeating: 0, count: manifest.classes.count * h * h)
            // An unknown class name plants nothing, and the test's score
            // assertions then fail on the missing entry — no force unwrap.
            for peak in peaks {
                if let cls = manifest.classes.firstIndex(of: peak.className) {
                    heatmap[cls * h * h + 10 * h + 10] = peak.score
                }
            }
            return OMRHeadOutputs(
                heatmap: heatmap,
                offset: [Float](repeating: 0, count: 2 * h * h),
                geom: [Float](repeating: 0, count: 4 * h * h),
                height: h, width: h,
            )
        }
    }

    /// The observer is the harness's only way to read a score, so it must
    /// see BOTH siblings with the score each was decoded at — and the
    /// glyph list the detector returns must be exactly the glyphs it saw.
    /// A tap that reported only the winner, or dropped the score, would
    /// turn "confidence split between siblings" back into "absent",
    /// which is the distinction the clef probe exists to make.
    @Test func theObserverSeesEverySiblingWithItsScore() throws {
        let manifest = OMRModelManifest(
            classes: OMRGlyphVocabulary.trainable, staffSpacePx: 12, tile: 384,
            overlap: 64, stride: 4, mean: 0, std: 1, threshold: 0.1, topK: 300,
            nmsRadiusSp: 0.5, decodeDefaultsMeasured: false, checkpoint: "test",
        )
        let classifier = SiblingPeaksClassifier(
            manifest: manifest, peaks: [("clefF", 0.2), ("clefF8va", 0.25)],
        )
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(page: Int, glyphs: [OMRGlyphDetector.ScoredGlyph])] = []
            func append(_ page: Int, _ glyphs: [OMRGlyphDetector.ScoredGlyph]) {
                lock.lock(); defer { lock.unlock() }
                items.append((page, glyphs))
            }

            var snapshot: [(page: Int, glyphs: [OMRGlyphDetector.ScoredGlyph])] {
                lock.lock(); defer { lock.unlock() }
                return items
            }
        }
        let seen = Seen()
        let detector = try OMRGlyphDetector(classifier: classifier) { page, glyphs in
            seen.append(page, glyphs)
        }
        // One tile exactly, at scale 1: 12 px staff spacing at 300 dpi is
        // 2.88 pt, and the normalizer then leaves the page alone.
        let side = 384
        let analysis = RasterPageAnalysis(
            paths: [],
            transform: PageTransform(dpi: 300, widthPx: side, heightPx: side, deskewDegrees: 0),
            staffSpacingPt: 12 * 72 / 300, deskewDegrees: 0,
            deskewed: GrayBitmap(
                pixels: [UInt8](repeating: 255, count: side * side), width: side, height: side, dpi: 300,
            ),
        )
        let glyphs = try detector.glyphs(pageIndex: 3, analysis: analysis, diagnostics: nil)

        let calls = seen.snapshot
        #expect(calls.count == 1)
        #expect(calls.first?.page == 3)
        let scored = calls.first?.glyphs ?? []
        #expect(scored.count == 2, "both siblings clear τ=0.1 and NMS is per class")
        #expect(scored.map(\.glyph) == glyphs, "the tap sees exactly what the detector returns")
        let byClass = Dictionary(
            uniqueKeysWithValues: scored.map {
                (OMRLabelClassNames.className(for: $0.glyph.semantic), $0.score)
            },
        )
        #expect(byClass["clefF"].map { abs($0 - 0.2) < 1e-6 } == true)
        #expect(byClass["clefF8va"].map { abs($0 - 0.25) < 1e-6 } == true)
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
