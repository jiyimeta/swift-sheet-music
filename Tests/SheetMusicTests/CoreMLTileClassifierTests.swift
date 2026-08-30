#if canImport(CoreML)
    import Foundation
    import SheetMusicOMRModel
    @testable import SheetMusicPDF
    import Testing

    struct CoreMLTileClassifierTests {
        /// The bundled model must load with NO environment variable and no
        /// caller-supplied path — that is the whole point of shipping it.
        @Test func theBundledModelLoadsWithNoConfiguration() async throws {
            let classifier = try await CoreMLTileClassifier()
            #expect(classifier.manifest.classes.count == 62)
            #expect(classifier.manifest.staffSpacePx == 12)
            // Task 11 flips this; until then the bundled constants are the
            // ones the frozen metric table was measured with.
            #expect(classifier.manifest.decodeDefaultsMeasured == false)
            #expect(classifier.manifest.threshold == 0.3)
        }

        /// The heads must come back at the shape OMRGlyphDetector's channel
        /// check expects, or every page throws.
        @Test func aBlankTileReturnsCorrectlyShapedHeads() async throws {
            let classifier = try await CoreMLTileClassifier()
            let manifest = classifier.manifest
            let heads = try classifier.run(
                tile: [Float](repeating: 0, count: manifest.tile * manifest.tile),
            )
            #expect(heads.heatmap.count == manifest.classes.count * heads.height * heads.width)
            #expect(heads.offset.count == 2 * heads.height * heads.width)
            #expect(heads.geom.count == 4 * heads.height * heads.width)
        }
    }
#endif
