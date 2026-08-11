#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterLayoutTests {
        private func staff(
            yMid: CGFloat,
            xRange: ClosedRange<CGFloat>,
            barlineXs: [CGFloat],
        ) -> Staff {
            let yLines = (-2 ... 2).map { yMid + CGFloat($0) * 5 }
            let yLo = yLines.first ?? yMid
            let yHi = yLines.last ?? yMid
            let bars = barlineXs.map {
                PathSegment(
                    kind: .vertical,
                    rect: CGRect(x: $0, y: yLo, width: 0, height: yHi - yLo),
                    lineWidth: 0.5,
                    pageIndex: 0,
                )
            }
            return Staff(
                pageIndex: 0,
                yLines: yLines,
                xRange: xRange,
                barlineCandidates: bars,
            )
        }

        private func notehead(x: CGFloat, y: CGFloat) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .noteheadBlack,
            )
        }

        private func capturedYs(
            staves: [Staff], glyphs: [ClassifiedGlyph], staffIndex: Int,
        ) -> [CGFloat] {
            let systems = PDFImporter.layoutSystems(
                staves: staves, paths: [], classified: glyphs, pageIndex: 0,
            )
            let all = systems.flatMap { $0.parts.flatMap(\.staves) }
            guard staffIndex < all.count else { return [] }
            return all[staffIndex].measures
                .flatMap { $0.glyphs.map(\.geometry.origin.y) }
                .sorted()
        }

        /// A DEEP LEDGER note still belongs to its staff.
        ///
        /// The pitch-bearing capture band used to stop 3 staff spaces past
        /// the outer line, which is inside the range real music writes. On a
        /// piano bass staff the lower note of an octave sits further out, and
        /// nothing claimed it: measured on `疑事無功_piano` page 1, 25 of 271
        /// noteheads were captured by NO staff, all of them 3.0–4.5 spaces
        /// beyond the nearest band. The visible symptom was octave dyads
        /// arriving as single notes — `[35, 47]` decoding as `[47]` — which
        /// looks like a chord-clustering bug and is not one.
        ///
        /// The band could be narrow because nothing else stopped a staff from
        /// reaching into its neighbour. The midpoint clamp does that now, so
        /// the band only has to be wide enough for real ledgers.
        @Test func aDeepLedgerNoteheadIsCapturedByItsOwnStaff() {
            let s = staff(yMid: 500, xRange: 50 ... 550, barlineXs: [550])
            // yLines are 490…510, so the staff's own spacing is 5pt.
            let deep = notehead(x: 200, y: 490 - 4 * 5) // 4 spaces below
            let ys = capturedYs(staves: [s], glyphs: [deep], staffIndex: 0)
            #expect(ys == [470], "\(ys)")
        }

        /// …but not past the midpoint to a neighbour. The clamp is what makes
        /// the wider band safe, so it is pinned here: a glyph in the gap
        /// between two staves goes to the nearer one and to that one only.
        @Test func theMidpointClampStillSplitsTwoCloseStaves() {
            let upper = staff(yMid: 540, xRange: 50 ... 550, barlineXs: [550])
            let lower = staff(yMid: 500, xRange: 50 ... 550, barlineXs: [550])
            // Upper spans 530…550, lower 490…510; midpoint of the gap is 520.
            let nearUpper = notehead(x: 200, y: 526)
            let nearLower = notehead(x: 200, y: 514)
            let upperYs = capturedYs(
                staves: [upper, lower], glyphs: [nearUpper, nearLower], staffIndex: 0,
            )
            let lowerYs = capturedYs(
                staves: [upper, lower], glyphs: [nearUpper, nearLower], staffIndex: 1,
            )
            #expect(upperYs == [526], "\(upperYs)")
            #expect(lowerYs == [514], "\(lowerYs)")
        }

        @Test func twoNearStavesFormOneSystem() {
            let s1 = staff(yMid: 700, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let s2 = staff(yMid: 660, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let systems = PDFImporter.layoutSystems(
                staves: [s1, s2], paths: [], classified: [], pageIndex: 0,
            )
            #expect(systems.count == 1)
            #expect(systems.first?.parts.flatMap(\.staves).count == 2)
        }

        @Test func farStavesSplitIntoTwoSystems() {
            let s1 = staff(yMid: 700, xRange: 50 ... 550, barlineXs: [550])
            let s2 = staff(yMid: 200, xRange: 50 ... 550, barlineXs: [550])
            let systems = PDFImporter.layoutSystems(
                staves: [s1, s2], paths: [], classified: [], pageIndex: 0,
            )
            #expect(systems.count == 2)
        }

        @Test func barlinesSplitMeasures() {
            let s = staff(yMid: 500, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let systems = PDFImporter.layoutSystems(
                staves: [s], paths: [], classified: [], pageIndex: 0,
            )
            let measures = systems.first?.parts.first?.staves.first?.measures ?? []
            // 3 cells: (50,200), (200,400), (400,550)
            #expect(measures.count == 3)
            #expect(abs(measures[0].xRange.lowerBound - 50) < 1)
            #expect(abs(measures[2].xRange.upperBound - 550) < 1)
        }

        @Test func bracketCouplesGrandStaff() {
            let upper = staff(yMid: 700, xRange: 50 ... 550, barlineXs: [550])
            let lower = staff(yMid: 660, xRange: 50 ... 550, barlineXs: [550])
            let bracket = PathSegment(
                kind: .vertical,
                rect: CGRect(x: 48, y: 658, width: 0, height: 44),
                lineWidth: 1.5, pageIndex: 0,
            )
            let systems = PDFImporter.layoutSystems(
                staves: [upper, lower], paths: [bracket],
                classified: [], pageIndex: 0,
            )
            #expect(systems.first?.parts.count == 1)
            #expect(systems.first?.parts.first?.staves.count == 2)
        }

        @Test func glyphsAreAssignedToTheirMeasureCell() {
            let s = staff(yMid: 500, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let g = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: 250, y: 500), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .noteheadBlack,
            )
            let systems = PDFImporter.layoutSystems(
                staves: [s], paths: [], classified: [g], pageIndex: 0,
            )
            let measures = systems.first?.parts.first?.staves.first?.measures ?? []
            #expect(measures[0].glyphs.isEmpty)
            #expect(measures[1].glyphs.count == 1)
            #expect(measures[2].glyphs.isEmpty)
        }

        /// Staves of one system must always end up with the SAME measure
        /// count — that is what this test is for, and it holds however the
        /// disagreement is resolved.
        ///
        /// The resolution itself changed. When one staff sees a barline the
        /// other does not, the layout used to adopt it (union) and this
        /// fixture produced `[3, 3]`; it now DROPS it, giving `[2, 2]`,
        /// because a real barline runs through every staff of a system and a
        /// single-staff vertical is a stray. The number here was never
        /// motivated by a score — this test predates the barline consensus
        /// entirely — whereas the change is: see
        /// `PDFImporterBarlineConsensusTests` and the `疑事無功_piano`
        /// measurement in `systemBarlineUnion`'s doc comment.
        @Test func crossStaffAlignmentUnifiesBarlines() {
            let s1 = staff(yMid: 700, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let s2 = staff(yMid: 660, xRange: 50 ... 550, barlineXs: [400, 550])
            let systems = PDFImporter.layoutSystems(
                staves: [s1, s2], paths: [], classified: [], pageIndex: 0,
            )
            let counts = systems.first?.parts.flatMap { $0.staves.map(\.measures.count) }
            #expect(counts == [2, 2])
            // The alignment invariant, stated independently of the number.
            #expect(Set(counts ?? []).count == 1, "\(counts ?? [])")
        }
    }
#endif
