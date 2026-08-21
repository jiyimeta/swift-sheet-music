#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    /// End-to-end coverage for per-staff line counts, read out of a real
    /// `.mscx` rather than a hand-built `Score`.
    ///
    /// `StaffLineCountLayoutTests` builds every one of its fixtures in
    /// Swift, so none of them crosses the MSCX reader: a
    /// `<StaffType><lines>` that never reached `Staff.lineCount` would
    /// leave that whole suite green. This one loads
    /// `Resources/staff-line-count.mscx` — three parts drawing 5 / 3 / 1
    /// lines, two measures each — and asserts the four line-count-
    /// dependent quantities that survive all the way into the laid-out
    /// document: the counts themselves, barline spans, ledger-line
    /// positions, and measure-rest placement.
    ///
    /// Split from `StaffLineCountLayoutTests` only because appending it
    /// there pushed that struct past SwiftLint's 400-line
    /// `type_body_length` cap.
    @Suite("Staff line count — MSCX fixture")
    struct StaffLineCountFixtureTests {
        private let _installApple = TestSupport.installApple

        /// `Resources/staff-line-count.mscx`, parsed and laid out.
        private func fixtureLayout() throws -> (score: Score, system: LayoutSystem) {
            let url = try #require(TestResources.url(
                forResource: "staff-line-count", withExtension: "mscx",
            ))
            let score = try MSCXParser.parse(Data(contentsOf: url))
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            return try (score, #require(doc.systems.first))
        }

        @Test("The three-staff fixture lays out with its declared line counts")
        func fixtureLineCounts() throws {
            guard #available(macOS 15.0, *) else { return }
            let (score, system) = try fixtureLayout()
            // The fixture omits `<lines>` on the first staff, so this
            // also pins the default rather than only the explicit values.
            #expect(score.parts.map { $0.staves[0].lineCount } == [5, 3, 1])
            #expect(system.staffGeometries.map(\.lineCount) == [5, 3, 1])
            #expect(system.staffOrigins.count == 3)
        }

        /// Both fixture measures end with an explicit `<BarLine>`, so
        /// this reaches the voice-driven barline branch in
        /// `LayoutEngine+Placement` rather than the synthesized trailing
        /// one the rest of the suite exercises.
        ///
        /// Spans are written as literals rather than re-derived from
        /// `barLineSpanY`, which would assert the implementation against
        /// itself: 4 sp for five lines, 2 sp for three, and ±2 sp ABOUT
        /// the single line for one.
        @Test("Fixture barlines span each staff's own lines")
        func fixtureBarLineSpans() throws {
            guard #available(macOS 15.0, *) else { return }
            let (_, system) = try fixtureLayout()
            let sp = system.sp
            let origins = system.staffOrigins.map(\.y)
            #expect(origins.count == 3)
            // Pinned, not read off `system`: `expected` is built by
            // iterating the measures, so a regression that emptied
            // `measures` would leave both lists empty and pass.
            #expect(system.measures.count == 2)

            var expected: [(top: CGFloat, bottom: CGFloat)] = []
            for _ in 0 ..< system.measures.count {
                expected.append((origins[0], origins[0] + sp * 4))
                expected.append((origins[1], origins[1] + sp * 2))
                expected.append((origins[2] - sp * 2, origins[2] + sp * 2))
            }

            var observed: [(top: CGFloat, bottom: CGFloat)] = []
            for measure in system.measures {
                for element in measure.elements {
                    guard case let .barLine(_, origin, halfHeight) = element
                    else { continue }
                    observed.append((
                        origin.y - halfHeight, origin.y + halfHeight,
                    ))
                }
            }
            #expect(observed.count == expected.count)
            for (obs, exp) in zip(
                observed.sorted { $0.top < $1.top },
                expected.sorted { $0.top < $1.top },
            ) {
                #expect(abs(obs.top - exp.top) < 0.001)
                #expect(abs(obs.bottom - exp.bottom) < 0.001)
            }
        }

        /// Every note in the fixture's first measure sits exactly one
        /// ledger position outside its own staff, so the six strokes
        /// below are six independent readings of `firstLedgerStepAbove` /
        /// `firstLedgerStepBelow`.
        ///
        /// Compared as one sorted list of absolute Y values rather than
        /// bucketed per staff: an offset measured against the wrong
        /// staff origin can coincide with a legitimate offset against
        /// the next one, and the total is what a line-count-blind bound
        /// gets wrong anyway — it draws four strokes, not six, because
        /// the 3- and 1-line staves' low notes fall inside a five-line
        /// frame.
        @Test("Fixture ledger lines start one space outside each staff")
        func fixtureLedgerLines() throws {
            guard #available(macOS 15.0, *) else { return }
            let (_, system) = try fixtureLayout()
            let sp = system.sp
            let origins = system.staffOrigins.map(\.y)
            #expect(origins.count == 3)

            // The top line sits at the staff origin, `step` 4 IS that
            // top line, and each step is half a space. Above-staff
            // ledgers are at step 6 for every line count; below-staff
            // ones follow the bottom line — step −6 / −2 / +2 for
            // 5 / 3 / 1 lines.
            let expected: [CGFloat] = [
                origins[0] - sp, origins[0] + sp * 5,
                origins[1] - sp, origins[1] + sp * 3,
                origins[2] - sp, origins[2] + sp,
            ].sorted()

            var observed: [CGFloat] = []
            for measure in system.measures {
                for element in measure.elements {
                    if case let .ledgerLine(from, _, _) = element {
                        observed.append(from.y)
                    }
                }
            }
            #expect(observed.count == expected.count)
            for (obs, exp) in zip(observed.sorted(), expected) {
                #expect(abs(obs - exp) < 0.001)
            }
        }

        /// The fixture's second measure is empty on all three staves.
        /// A measure rest is the one element whose Y depends on the line
        /// count twice over — `naturalRestLine` picks the line it
        /// centers on, and `wholeRestLineMove` decides whether it then
        /// hangs from the line above. On a ONE-line staff it does not,
        /// which is why the expected offsets are not simply
        /// `naturalRestLine − 1` throughout.
        ///
        /// `RestID` carries the originating `StaffAddress`, so unlike
        /// the barlines and ledger lines these are attributed exactly
        /// rather than matched as a set.
        @Test("Fixture measure rests sit on each staff's own natural line")
        func fixtureMeasureRestPlacement() throws {
            guard #available(macOS 15.0, *) else { return }
            let (_, system) = try fixtureLayout()
            let sp = system.sp
            let lastMeasure = try #require(system.measures.last)

            var offsetByStaff: [Int: CGFloat] = [:]
            for element in lastMeasure.elements {
                guard case let .rest(_, origin, _, restID, _) = element,
                      let flat = system.flatIndex(for: restID.staff)
                else { continue }
                offsetByStaff[flat] =
                    origin.y - system.staffOrigins[flat].y
            }
            #expect(offsetByStaff.count == 3)
            // 5 lines: natural line 2, hung one line above → 1 sp below
            // the top line. 3 lines: natural line 1, hung one above →
            // ON the top line. 1 line: natural line 0 and no hang → on
            // the single line.
            #expect(abs((offsetByStaff[0] ?? .nan) - sp) < 0.001)
            #expect(abs(offsetByStaff[1] ?? .nan) < 0.001)
            #expect(abs(offsetByStaff[2] ?? .nan) < 0.001)
        }
    }
#endif
