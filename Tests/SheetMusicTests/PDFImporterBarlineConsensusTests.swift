#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// A barline is engraved straight down through the whole system, so it
    /// appears at ~the same x in every staff. `systemBarlineUnion` uses that
    /// to reject a stray vertical — a tall stem, a slur arm, an ottava hook —
    /// that only one staff sees.
    ///
    /// The consensus was gated to systems of THREE staves or more, on the
    /// reasoning that two staves cannot form a quorum. A GRAND STAFF is
    /// exactly two staves, so every piano score fell back to the raw union
    /// and any single-staff vertical became a system-wide measure boundary.
    /// Measured on `疑事無功_piano` (55 measures of ground truth): two
    /// single-staff verticals — `x=238 y=530..583 w=3.27` on the treble of
    /// one system, `x=175 y=526..566 w=3.27` on the bass of another —
    /// carved two extra cells, and every measure after the first shifted by
    /// one. Positional pitch read 8% while the note decode itself was fine
    /// (the shifted measures' contents match the ground truth exactly, one
    /// index over).
    ///
    /// Every real barline in that score appeared on BOTH staves; only the two
    /// strays were single-staff. So two staves DO form a quorum: require
    /// both.
    @MainActor struct PDFImporterBarlineConsensusTests {
        private func staff(
            yLines: [CGFloat], barlineXs: [CGFloat],
        ) -> SheetMusicPDF.Staff {
            SheetMusicPDF.Staff(
                pageIndex: 0,
                yLines: yLines,
                xRange: 50 ... 550,
                barlineCandidates: barlineXs.map { x in
                    PathSegment(
                        kind: .vertical,
                        rect: CGRect(
                            x: x,
                            y: yLines.first ?? 0,
                            width: 0,
                            height: (yLines.last ?? 0) - (yLines.first ?? 0),
                        ),
                        lineWidth: 1, pageIndex: 0,
                    )
                },
            )
        }

        private func system(_ staves: [SheetMusicPDF.Staff]) -> ImportSystem {
            ImportSystem(
                pageIndex: 0, yRange: 400 ... 560,
                parts: [ImportPart(staves: staves.map {
                    ImportStaff(staff: $0, measures: [])
                })],
            )
        }

        /// The grand-staff case that was falling through to the raw union.
        @Test func aStrayVerticalOnOneStaffOfAGrandStaffIsRejected() {
            let treble = staff(
                yLines: [529, 535, 541, 547, 553],
                barlineXs: [52, 238, 279, 411, 552],
            )
            let bass = staff(
                yLines: [482, 488, 494, 500, 505],
                barlineXs: [52, 279, 411, 552],
            )
            let xs = PDFImporter.systemBarlineUnion(system([treble, bass]))
            #expect(!xs.contains { abs($0 - 238) < 5 }, "\(xs)")
            for real in [52.0, 279.0, 411.0, 552.0] {
                #expect(xs.contains { abs($0 - real) < 5 }, "missing \(real) in \(xs)")
            }
        }

        /// A barline both staves see survives even when their detected x
        /// differs slightly — the clustering tolerance is about a staff
        /// space, so the two votes must still land in one cluster.
        @Test func aSharedBarlineSurvivesASmallXDisagreement() {
            let treble = staff(
                yLines: [529, 535, 541, 547, 553],
                barlineXs: [52, 300, 552],
            )
            let bass = staff(
                yLines: [482, 488, 494, 500, 505],
                barlineXs: [52, 302, 552],
            )
            let xs = PDFImporter.systemBarlineUnion(system([treble, bass]))
            #expect(xs.contains { abs($0 - 301) < 3 }, "\(xs)")
            // …and the two votes collapse to ONE split, rather than the
            // disagreement itself carving a 2pt cell.
            #expect(xs.count == 3, "\(xs)")
            for real in [52.0, 552.0] {
                #expect(xs.contains { abs($0 - real) < 1 }, "missing \(real) in \(xs)")
            }
        }

        /// A SOLO staff has nobody to agree with, so consensus cannot apply
        /// and the raw union must be kept — otherwise a one-staff score
        /// loses every barline it has.
        @Test func aSingleStaffSystemKeepsItsRawUnion() {
            let only = staff(
                yLines: [529, 535, 541, 547, 553],
                barlineXs: [52, 238, 279, 552],
            )
            let xs = PDFImporter.systemBarlineUnion(system([only]))
            #expect(xs.count == 4, "\(xs)")
            #expect(xs.contains { abs($0 - 238) < 1 }, "\(xs)")
        }

        /// Three or more staves keep the behaviour they already had.
        @Test func aThreeStaffSystemStillRejectsASingleStaffStray() {
            let a = staff(
                yLines: [529, 535, 541, 547, 553],
                barlineXs: [52, 238, 279, 552],
            )
            let b = staff(
                yLines: [482, 488, 494, 500, 505],
                barlineXs: [52, 279, 552],
            )
            let c = staff(
                yLines: [435, 441, 447, 453, 459],
                barlineXs: [52, 279, 552],
            )
            let xs = PDFImporter.systemBarlineUnion(system([a, b, c]))
            #expect(!xs.contains { abs($0 - 238) < 5 }, "\(xs)")
            #expect(xs.count == 3, "\(xs)")
        }
    }
#endif
