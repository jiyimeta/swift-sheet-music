#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// Header columns: the clef / key signature / time signature row a
    /// measure draws before its first note. The columns are nominal
    /// widths, but what the reader sees is the glyph INK inside them, so
    /// every assertion here is on the drawn span rather than the column.
    ///
    /// MuseScore keeps `keyTimesigDistance` (1 sp, `styledef.cpp`) between
    /// the key signature's shape and the time signature's, and its
    /// shapes are the union of the accidental bounding boxes
    /// (`TLayout::layoutKeySig` builds `keySigShape` from
    /// `symShapeWithCutouts`). A column sized from an accidental COUNT
    /// rather than that ink is what lets the last sharp of a wide key
    /// reach into the numbers.
    @Suite("Header signature spacing")
    struct HeaderSignatureSpacingTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        enum TestFailure: Error { case notFound(String) }

        // MARK: - Fixtures

        private static func score(
            key: Int,
            time: (Int, Int) = (4, 4),
            clefType: String = "G",
        ) -> Score {
            let elements: [VoiceElement] = [
                .clef(Clef(concertClefType: clefType)),
                .keySignature(KeySignature(concertKey: key)),
                .timeSignature(TimeSignature(
                    numerator: time.0, denominator: time.1,
                )),
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                )),
            ]
            let staff = Staff(measures: [
                Measure(voices: [Voice(elements: elements)]),
            ])
            let part = Part(
                id: "P0",
                instrument: Instrument(id: "voice0"),
                staves: [staff],
            )
            return Score(division: 480, parts: [part])
        }

        private func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 900,
            )
        }

        // MARK: - Readers

        /// Horizontal ink of a key / time signature element, measure-local.
        /// Mirrors what the renderers draw: `KeySignatureRenderer` strides
        /// accidentals by `KeySignatureSteps.advance` and centers each
        /// glyph on its stride; `TimeSignatureRenderer` does the same with
        /// `TimeSignatureLayout.digitAdvance`.
        private func keyInk(
            _ m: LayoutMeasure, sp: CGFloat,
        ) throws -> (left: CGFloat, right: CGFloat) {
            for element in m.elements {
                guard case let .keySignature(sharps, flats, _, naturals, origin, _)
                    = element else { continue }
                let count = naturals.count + sharps + flats
                guard count > 0 else { continue }
                let half = KeySignatureSteps.glyphWidth(sp: sp) / 2
                let stride = KeySignatureSteps.advance(sp: sp)
                    * CGFloat(count - 1)
                return (origin.x - half, origin.x + stride + half)
            }
            throw TestFailure.notFound("key signature")
        }

        private func timeInk(
            _ m: LayoutMeasure, sp: CGFloat,
        ) throws -> (left: CGFloat, right: CGFloat) {
            for element in m.elements {
                guard case let .timeSignature(numerator, denominator, _, origin, _)
                    = element else { continue }
                let digits = max(
                    String(numerator).count, String(denominator).count,
                )
                let half = TimeSignatureLayout.digitWidth(sp: sp) / 2
                let stride = TimeSignatureLayout.digitAdvance(sp: sp)
                    * CGFloat(digits - 1)
                return (origin.x - half, origin.x + stride + half)
            }
            throw TestFailure.notFound("time signature")
        }

        private func headMeasure(_ doc: LayoutDocument) throws -> LayoutMeasure {
            for system in doc.systems {
                for m in system.measures where m.measureIndex == 0 {
                    return m
                }
            }
            throw TestFailure.notFound("measure 0")
        }

        // MARK: - Tests

        /// Every key width from C major to seven accidentals, both
        /// directions: the last accidental's ink must clear the first
        /// digit's by MuseScore's `keyTimesigDistance`.
        @Test(
            "a header key signature never reaches into the time signature",
            arguments: [-7, -6, -5, -4, -3, -2, -1, 1, 2, 3, 4, 5, 6, 7],
        )
        func keySignatureClearsTimeSignature(key: Int) throws {
            let doc = layout(Self.score(key: key))
            let sp = doc.metrics.sp
            let m = try headMeasure(doc)
            let keys = try keyInk(m, sp: sp)
            let times = try timeInk(m, sp: sp)
            #expect(
                times.left - keys.right
                    >= LayoutEngine.keyTimeSignatureGap(sp: sp) - 0.0001,
                """
                key \(key): ink gap \(times.left - keys.right) sp is under \
                the required \(LayoutEngine.keyTimeSignatureGap(sp: sp))
                """,
            )
        }

        /// A multi-digit meter widens its own row to the LEFT of the
        /// origin only by half a digit, so the check above stays the
        /// binding one — but the wide key + wide meter pair is the case a
        /// reader actually meets in a 12/8 modulation.
        @Test("a two-digit meter clears a seven-accidental key")
        func wideMeterClearsWideKey() throws {
            let doc = layout(Self.score(key: -7, time: (12, 8)))
            let sp = doc.metrics.sp
            let m = try headMeasure(doc)
            let keys = try keyInk(m, sp: sp)
            let times = try timeInk(m, sp: sp)
            #expect(
                times.left - keys.right
                    >= LayoutEngine.keyTimeSignatureGap(sp: sp) - 0.0001,
            )
        }
    }
#endif
