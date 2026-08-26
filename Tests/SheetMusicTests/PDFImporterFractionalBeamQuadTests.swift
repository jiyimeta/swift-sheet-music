#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// Unit tests for `PDFPageState.emitBeamIfQuad`'s minimum-width gate.
    ///
    /// A fractional (partial) beam — the stub hanging off the sixteenth of a
    /// dotted-eighth + sixteenth pair — is the SHORTEST beam quad MuseScore
    /// ever draws: roughly 1.25 spaces. On a densely engraved score (six
    /// staves on one page ⇒ ~2.85pt per space) that is only ~3.6pt wide, so
    /// an absolute 4pt floor rejected it. The quad then fell through to the
    /// per-edge line capture, where its two long edges became `.horizontal`
    /// segments and its two short edges became phantom `.vertical` "stems" —
    /// and the sixteenth, having lost its only secondary beam, was read as an
    /// eighth. These pin the floor low enough for real fractional beams while
    /// keeping the sub-2pt noise floor.
    ///
    /// Driven through the page state directly: no corpus PDF is engraved
    /// small enough to exercise this, which is exactly why it regressed
    /// unnoticed.
    struct PDFImporterFractionalBeamQuadTests {
        /// Push a filled parallelogram (4 corners, `m l l l f`) through the
        /// page state and return the segments it produced.
        private func fill(
            corners: [CGPoint], pageState state: PDFPageState = .init(pageIndex: 0),
        ) -> [PathSegment] {
            state.opMoveTo(x: corners[0].x, y: corners[0].y)
            for p in corners.dropFirst() {
                state.opLineTo(x: p.x, y: p.y)
            }
            state.opFill()
            return state.paths
        }

        /// A beam slab `w` wide and `thickness` tall, bottom-left at (x, y).
        private func slab(
            x: CGFloat, y: CGFloat, width: CGFloat, thickness: CGFloat = 1.4,
        ) -> [CGPoint] {
            [
                CGPoint(x: x, y: y),
                CGPoint(x: x + width, y: y),
                CGPoint(x: x + width, y: y + thickness),
                CGPoint(x: x, y: y + thickness),
            ]
        }

        @Test func fractionalBeamNarrowerThanFourPointsIsABeam() {
            // Measured off a real six-staff MuseScore export: the stub over
            // the sixteenth of a dotted-eighth pair is 3.7 x 1.4pt.
            let segments = fill(corners: slab(x: 449.4, y: 226.5, width: 3.7))
            #expect(segments.count == 1)
            let beam = segments.first
            #expect(beam?.kind == .beam)
            #expect(beam?.quad != nil)
            #expect(abs((beam?.rect.width ?? 0) - 3.7) < 0.001)
        }

        /// The edges must NOT also be emitted: the two short vertical edges
        /// sit exactly at the stub's x-ends, where `stubOwner` looks for the
        /// stem that owns the stub. Left in the path list they win the
        /// nearest-stem contest against the real stem and the secondary level
        /// lands on a phantom.
        @Test func fractionalBeamDoesNotAlsoEmitItsEdges() {
            let segments = fill(corners: slab(x: 449.4, y: 226.5, width: 3.7))
            #expect(!segments.contains { $0.kind == .vertical })
            #expect(!segments.contains { $0.kind == .horizontal })
        }

        @Test func subTwoPointQuadIsStillRejected() {
            let segments = fill(corners: slab(x: 100, y: 200, width: 1.5))
            #expect(!segments.contains { $0.kind == .beam })
        }

        /// The upper bounds are untouched: a full stem-to-stem beam and the
        /// too-tall / too-wide rejections behave exactly as before.
        @Test func fullWidthBeamIsUnaffected() {
            let segments = fill(corners: slab(x: 433.6, y: 228.6, width: 19.5))
            #expect(segments.count == 1)
            #expect(segments.first?.kind == .beam)
        }

        @Test func tooTallQuadIsStillRejected() {
            let segments = fill(
                corners: slab(x: 100, y: 200, width: 20, thickness: 14),
            )
            #expect(!segments.contains { $0.kind == .beam })
        }
    }
#endif
