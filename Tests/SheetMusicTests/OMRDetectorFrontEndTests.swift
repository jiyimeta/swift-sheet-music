#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    @testable import SheetMusicUI
    import Testing

    /// The vocabulary check is the one gate here that never needs a
    /// model: `OMRDetectorFrontEnd.checkVocabulary` is pure, and these
    /// four cases are the whole of that gate's evidence (task-14 brief). A
    /// model whose class list disagrees with the frozen table — reorder,
    /// unknown name, wrong length — must throw, not warn: it would
    /// otherwise assemble a plausible-looking score out of the wrong
    /// symbols and nothing downstream would notice.
    struct OMRDetectorFrontEndTests {
        @Test func aModelWhoseClassListMatchesTheFrozenTableLoads() throws {
            try OMRDetectorFrontEnd.checkVocabulary(OMRPrepTargets.trainableVocabulary)
        }

        @Test func aReorderedClassListIsRejected() {
            var classes = OMRPrepTargets.trainableVocabulary
            classes.swapAt(0, 1)
            // A model whose class 7 means something else than the table's
            // class 7 builds a plausible score out of the wrong symbols,
            // and nothing downstream notices. This must throw, not warn.
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkVocabulary(classes)
            }
        }

        @Test func anUnknownClassNameIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkVocabulary(
                    OMRPrepTargets.trainableVocabulary + ["noteheadTriangle"],
                )
            }
        }

        @Test func aShortClassListIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkVocabulary(
                    Array(OMRPrepTargets.trainableVocabulary.dropLast()),
                )
            }
        }

        /// A same-length, reordered class list is the load-bearing case
        /// (index 7 quietly meaning something else than the frozen
        /// table's index 7) and the hardest to notice from a bare
        /// "N classes does not match M classes" message, since N == M
        /// here. The error must name the first differing index and both
        /// class names there.
        @Test func aReorderedClassListNamesTheFirstDifferingIndexAndBothNames() {
            var classes = OMRPrepTargets.trainableVocabulary
            classes.swapAt(0, 1)
            do {
                try OMRDetectorFrontEnd.checkVocabulary(classes)
                Issue.record("expected checkVocabulary to throw")
            } catch {
                guard case let SheetMusicError.malformedScore(reason) = error else {
                    Issue.record("expected .malformedScore, got \(error)")
                    return
                }
                #expect(reason.contains("index 0"))
                #expect(reason.contains(classes[0]))
                #expect(reason.contains(OMRPrepTargets.trainableVocabulary[0]))
            }
        }
    }

    /// `checkNumerics` is pure, same reasoning as `checkVocabulary`: a
    /// manifest field that decodes fine but is semantically nonsense
    /// (`staff_space_px: 0`) must throw at load time rather than let
    /// `glyphs(page:analysis:)` silently return `[]` on every page and
    /// read as a clean `recall=0.0000` (task-14 brief follow-up). `std`
    /// and `overlap` reach the same class of silent failure by their own
    /// roads — see `checkNumerics`' doc comment — and are covered here
    /// too.
    struct OMRDetectorFrontEndNumericsTests {
        private static func sampleManifest(
            staffSpacePx: Double = 12, tile: Int = 384, overlap: Int = 64, stride: Int = 4,
            std: Double = 1, topK: Int = 300,
        ) -> OMRDetectorFrontEnd.Manifest {
            OMRDetectorFrontEnd.Manifest(
                classes: OMRPrepTargets.trainableVocabulary,
                staffSpacePx: staffSpacePx, tile: tile, overlap: overlap, stride: stride,
                mean: 0, std: std, threshold: 0.3, topK: topK, nmsRadiusSp: 0.5,
                decodeDefaultsMeasured: false, checkpoint: "random",
            )
        }

        @Test func aManifestWithAllPositiveFieldsLoads() throws {
            try OMRDetectorFrontEnd.checkNumerics(Self.sampleManifest())
        }

        @Test func aZeroStaffSpacePxIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkNumerics(Self.sampleManifest(staffSpacePx: 0))
            }
        }

        @Test func aZeroTileIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkNumerics(Self.sampleManifest(tile: 0))
            }
        }

        @Test func aZeroStrideIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkNumerics(Self.sampleManifest(stride: 0))
            }
        }

        @Test func aZeroTopKIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkNumerics(Self.sampleManifest(topK: 0))
            }
        }

        /// `std: 0` decodes fine but divides by zero in `makeInput`'s
        /// `(raw - mean) / std`, turning every tile's input — and so the
        /// model's output — into NaN. That reads exactly like the
        /// `staff_space_px: 0` failure this gate already guards: a
        /// clean-looking empty sweep with no diagnostic anywhere.
        @Test func aZeroStdIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkNumerics(Self.sampleManifest(std: 0))
            }
        }

        /// A negative `overlap` does not fail outright (`OMRTiling.
        /// origins`' step clamps to `max(1, tile - overlap)`) — it
        /// silently opens a gap between adjacent tiles' pixel windows
        /// that `OMRTiling.coreRange`'s midpoint partition has no way to
        /// notice, so pixels in the gap are never run through the model
        /// by any tile and vanish from every detection.
        @Test func aNegativeOverlapIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkNumerics(Self.sampleManifest(overlap: -1))
            }
        }

        /// Spec §11's sweep varies the three decode constants over ONE
        /// exported model, via the environment.
        @Test func decodeOverridesReplaceOnlyTheThreeDecodeConstants() {
            let base = Self.sampleManifest()
            let out = OMRDetectorFrontEnd.applyDecodeOverrides(
                to: base,
                environment: [
                    "OMR_DECODE_THRESHOLD": "0.45",
                    "OMR_DECODE_TOP_K": "120",
                    "OMR_DECODE_NMS_SP": "0.75",
                ],
            )
            #expect(out.threshold == 0.45)
            #expect(out.topK == 120)
            #expect(out.nmsRadiusSp == 0.75)

            // Everything the weights and the exported graph are baked
            // against must be untouched — S and T especially: a model
            // trained at S=12 does not become an S=16 model by being told
            // so, it becomes a wrong one.
            #expect(out.staffSpacePx == base.staffSpacePx)
            #expect(out.tile == base.tile)
            #expect(out.overlap == base.overlap)
            #expect(out.stride == base.stride)
            #expect(out.mean == base.mean)
            #expect(out.std == base.std)
            #expect(out.classes == base.classes)
            #expect(out.checkpoint == base.checkpoint)
            // An override is not a measurement.
            #expect(out.decodeDefaultsMeasured == base.decodeDefaultsMeasured)
        }

        @Test func anEmptyEnvironmentLeavesTheManifestExactlyAsDecoded() {
            let base = Self.sampleManifest()
            let out = OMRDetectorFrontEnd.applyDecodeOverrides(to: base, environment: [:])
            #expect(out.threshold == base.threshold)
            #expect(out.topK == base.topK)
            #expect(out.nmsRadiusSp == base.nmsRadiusSp)
        }

        /// Each variable is independent — a sweep over τ alone must not
        /// disturb top-K or the NMS radius. Without this, one `if` block
        /// reading another's variable would pass every assertion above.
        @Test func eachDecodeOverrideActsAlone() {
            let base = Self.sampleManifest()
            let onlyThreshold = OMRDetectorFrontEnd.applyDecodeOverrides(
                to: base, environment: ["OMR_DECODE_THRESHOLD": "0.9"],
            )
            #expect(onlyThreshold.threshold == 0.9)
            #expect(onlyThreshold.topK == base.topK)
            #expect(onlyThreshold.nmsRadiusSp == base.nmsRadiusSp)

            let onlyTopK = OMRDetectorFrontEnd.applyDecodeOverrides(
                to: base, environment: ["OMR_DECODE_TOP_K": "7"],
            )
            #expect(onlyTopK.topK == 7)
            #expect(onlyTopK.threshold == base.threshold)
            #expect(onlyTopK.nmsRadiusSp == base.nmsRadiusSp)

            let onlyNms = OMRDetectorFrontEnd.applyDecodeOverrides(
                to: base, environment: ["OMR_DECODE_NMS_SP": "1.25"],
            )
            #expect(onlyNms.nmsRadiusSp == 1.25)
            #expect(onlyNms.threshold == base.threshold)
            #expect(onlyNms.topK == base.topK)
        }

        /// An overridden value goes through `checkNumerics` like any
        /// other, so a sweep cannot walk into a configuration the loader
        /// would have refused from a manifest — `top_k: 0` detects
        /// nothing and reads as a detector failure.
        @Test func anOverriddenValueIsStillCheckedForSanity() {
            let out = OMRDetectorFrontEnd.applyDecodeOverrides(
                to: Self.sampleManifest(), environment: ["OMR_DECODE_TOP_K": "0"],
            )
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkNumerics(out)
            }
        }
    }

    /// `model.json`'s `decode_defaults_measured` and `checkpoint` fields
    /// used to pass through `Manifest` entirely unread — `JSONDecoder`
    /// silently ignores any key with no matching property, so a typo'd
    /// property name would have failed exactly the same silent way. Both
    /// are now load-bearing: the eval harness's summary line prints
    /// `decodeDefaultsMeasured` (finding #5) and
    /// `OMRDetectorFrontEndModelTests` reads `checkpoint` (finding #3).
    struct OMRDetectorFrontEndManifestDecodeTests {
        @Test func decodesDecodeDefaultsMeasuredAndCheckpointFromRealExportShapedJSON() throws {
            // Same key set/shapes `Training/model/export.py`'s
            // `_write_manifest` writes (see that function), including the
            // provenance keys `Manifest` deliberately does NOT decode.
            let classesJSON = OMRPrepTargets.trainableVocabulary
                .map { "\"\($0)\"" }.joined(separator: ",")
            let json = """
            {
              "classes": [\(classesJSON)],
              "staff_space_px": 12.0,
              "tile": 384,
              "overlap": 64,
              "stride": 4,
              "mean": 0.0,
              "std": 1.0,
              "threshold": 0.3,
              "top_k": 300,
              "nms_radius_sp": 0.5,
              "decode_defaults_measured": true,
              "commit": "abc123",
              "training_config_hash": "def456",
              "prep_root": "/some/path",
              "seed": 42,
              "checkpoint": "/Users/x/run1-train/checkpoint.pt"
            }
            """
            let manifest = try JSONDecoder().decode(
                OMRDetectorFrontEnd.Manifest.self, from: Data(json.utf8),
            )
            #expect(manifest.decodeDefaultsMeasured == true)
            #expect(manifest.checkpoint == "/Users/x/run1-train/checkpoint.pt")
        }
    }

    /// Gated on a real model directory — none exists on this machine yet
    /// (task-14 brief). Point `OMR_MODEL_ROOT` at a directory holding
    /// `model.mlpackage` / `model.json`, as written by
    /// `Training/model/export.py` (e.g. its `--checkpoint random` output,
    /// the P3d-G1 floor).
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_MODEL_ROOT"] != nil))
    struct OMRDetectorFrontEndModelTests {
        /// A bare 5-line staff with NO symbols on it — the fixture this
        /// test used to carry — is not just an easy fixture, it is a
        /// page with NOTHING in the trainable vocabulary to detect
        /// (`staff5Lines` is explicitly excluded, see
        /// `OMRPrepTargets.isTrainable`). A real trained checkpoint
        /// correctly finding nothing there is not evidence of a broken
        /// round trip; it is the expected behavior of a well-calibrated
        /// detector on a symbol-free page. Verified empirically against
        /// `~/omr-models/run1` (8-epoch smoke checkpoint) while fixing
        /// this test: the bare-staff fixture returned 0 glyphs even from
        /// the trained model, and a rendered page carrying an actual
        /// clef + 4 notes returned 5 (see the fix report) — so the
        /// fixture, not the "must find something" assumption, was wrong.
        /// This renders a real clef + 4 notes through the same
        /// `ScoreLayerBuilder` CALayer path the corpus pixel gate uses
        /// (`CanvasInkProbe`'s own doc comment), giving the trained
        /// checkpoint actual SMuFL ink to find.
        @MainActor
        static func realPageWithSymbols() throws -> (bitmap: GrayBitmap, page: OMRPageLabels) {
            guard #available(macOS 15.0, *) else {
                throw SheetMusicError.malformedScore(reason: "requires macOS 15")
            }
            _ = TestSupport.installApple

            func note(_ pitch: Int) -> Note {
                Note(pitch: pitch, tpc: 14)
            }
            let chords = [60, 62, 64, 67].map { Chord(duration: .quarter, notes: [note($0)]) }
            let measure = Measure(voices: [Voice(
                elements:
                [.clef(Clef(concertClefType: "G"))] + chords.map { .chord($0) },
            )])
            let staff = Staff(measures: [measure])
            let score = Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
            )

            let opts = ScoreViewOptions(staffSize: 28, systemGap: 40, wrapToViewWidth: false)
            let natW = LayoutEngine.naturalContentWidth(score: score, options: opts)
            let doc = LayoutEngine.layout(score: score, options: opts, availableWidth: natW)
            let system = try #require(doc.systems.first)
            let tree = ScoreLayerBuilder.buildSystem(system, metrics: doc.metrics)
            tree.layoutIfNeeded()

            // Margin so the top staff line / ledger lines above it are
            // not clipped flush to the canvas edge.
            let margin = 20.0
            let scale = 4.0
            let width = Int(ceil(system.size.width * scale))
            let height = Int(ceil((system.size.height + margin) * scale))
            let ctx = try #require(CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue,
            ))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.translateBy(x: 0, y: margin * scale)
            ctx.scaleBy(x: scale, y: scale)
            tree.render(in: ctx)
            let raw = try #require(ctx.data)
            let bytes = raw.bindMemory(to: UInt8.self, capacity: width * height)
            let pixels = (0 ..< (width * height)).map { bytes[$0] }

            let dpi = 72.0 * scale
            let bitmap = GrayBitmap(pixels: pixels, width: width, height: height, dpi: dpi)
            let page = OMRPageLabels(
                schema: 1,
                page: OMRPageLabels.Page(
                    index: 0,
                    widthPt: Double(width) * 72.0 / dpi, heightPt: Double(height) * 72.0 / dpi,
                ),
                image: OMRPageLabels.Image(
                    file: "page.png", dpi: Int(dpi),
                    labelTransform: [1, 0, 0, 0, 1, 0, 0, 0, 1], sourceSizePx: nil,
                ),
                glyphs: [], paths: [], beams: [], curves: [], texts: [],
                census: OMRPageLabels.Census(glyphsByClass: [:], texts: 0),
            )
            return (bitmap, page)
        }

        // The bare `guard #available(macOS 15.0, *) else { return }` this
        // test used to open with made it pass silently on macOS 14 — an
        // absence with no signal, which this round's standing rule
        // forbids. `@available` on the test declaration itself is the
        // house pattern (see `AnacrusisTests`, `AnnotationTextClampTests`,
        // …): Swift Testing reports the test as explicitly SKIPPED for
        // an unmet platform requirement rather than silently passed.
        @MainActor
        @available(macOS 15.0, *)
        @Test func aRealModelProducesGlyphsInPageSpace() async throws {
            let path = try #require(ProcessInfo.processInfo.environment["OMR_MODEL_ROOT"])
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let frontEnd = try await OMRDetectorFrontEnd(modelRoot: root)

            let (bitmap, page) = try Self.realPageWithSymbols()
            let analysis = RasterPage.analyze(bitmap, pageIndex: 0, keepDeskewed: true)
            let glyphs = try frontEnd.glyphs(page: page, analysis: analysis)
            // The floor model (`--checkpoint random`) is untrained BY
            // DESIGN and must find NOTHING — it exists as the P3d-G1
            // floor, not as a candidate detector (verified: the
            // CenterNet prior bias keeps every class's sigmoid output
            // near 0.1, well under the 0.3 decode threshold). A trained
            // checkpoint on a page carrying real symbols is expected to
            // find something. Splitting on `checkpoint` is what makes
            // this test constructible-to-fail for "the whole Core ML
            // round trip silently stopped producing output": a bare
            // `for glyph in glyphs { #expect(...) }` with no population
            // check passes vacuously against the floor model, which is
            // exactly the failure mode this test used to have (see the
            // fix report).
            if frontEnd.checkpoint == "random" {
                #expect(glyphs.isEmpty)
            } else {
                #expect(!glyphs.isEmpty)
            }
            // Every glyph it finds must sit on this page, in page space.
            let pageSize = analysis.pageSizePt
            for glyph in glyphs {
                #expect(glyph.geometry.pageIndex == 0)
                #expect(glyph.geometry.origin.x >= -1 && glyph.geometry.origin.x <= pageSize.width + 1)
                #expect(glyph.geometry.origin.y >= -1 && glyph.geometry.origin.y <= pageSize.height + 1)
            }
        }
    }
#endif
