#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// End-of-system courtesy signatures: when the measure that OPENS the
    /// next system begins with an explicit key / time signature change,
    /// the current system's last measure announces it at its trailing
    /// edge. `showCourtesy == false` on the model element suppresses the
    /// announcement; a change that lands mid-system stays inline.
    @Suite("Courtesy signatures")
    struct CourtesySignatureLayoutTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        enum TestFailure: Error { case notFound(String) }

        // MARK: - Fixtures

        private static func chord() -> VoiceElement {
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            ))
        }

        /// One staff's four bars:
        ///
        /// * m0 — clef + `firstKey` + 4/4, one chord.
        /// * m1 — one chord and NOTHING else, so any signature element
        ///   laid out inside it can only be a courtesy.
        /// * m2 — the change: `secondKey` and, when `timeChange` is set,
        ///   a new time signature too.
        /// * m3 — one chord.
        ///
        /// `breakAfterM1` plants an explicit line break so the change
        /// reliably opens system 2 whatever the available width is.
        private static func staff(
            firstKey: Int,
            secondKey: Int,
            timeChange: (Int, Int)?,
            showCourtesy: Bool,
            breakAfterM1: Bool,
            clefType: String,
        ) -> Staff {
            var key = KeySignature(concertKey: secondKey)
            key.showCourtesy = showCourtesy
            var change: [VoiceElement] = [.keySignature(key)]
            if let timeChange {
                var time = TimeSignature(
                    numerator: timeChange.0, denominator: timeChange.1,
                )
                time.showCourtesy = showCourtesy
                change.append(.timeSignature(time))
            }
            change.append(chord())
            return Staff(measures: [
                Measure(voices: [Voice(elements: [
                    .clef(Clef(concertClefType: clefType)),
                    .keySignature(KeySignature(concertKey: firstKey)),
                    .timeSignature(
                        TimeSignature(numerator: 4, denominator: 4),
                    ),
                    chord(),
                ])]),
                Measure(
                    voices: [Voice(elements: [chord()])],
                    lineBreak: breakAfterM1,
                ),
                Measure(voices: [Voice(elements: change)]),
                Measure(voices: [Voice(elements: [chord()])]),
            ])
        }

        private static func score(
            firstKey: Int = 1,
            secondKey: Int = -2,
            timeChange: (Int, Int)? = (3, 4),
            showCourtesy: Bool = true,
            breakAfterM1: Bool = true,
            clefTypes: [String] = ["G"],
        ) -> Score {
            Score(
                division: 480,
                parts: clefTypes.enumerated().map { idx, clefType in
                    Part(
                        id: "P\(idx)",
                        instrument: Instrument(id: "voice\(idx)"),
                        staves: [staff(
                            firstKey: firstKey,
                            secondKey: secondKey,
                            timeChange: timeChange,
                            showCourtesy: showCourtesy,
                            breakAfterM1: breakAfterM1,
                            clefType: clefType,
                        )],
                    )
                },
            )
        }

        private func layout(
            _ score: Score, width: CGFloat = 900,
        ) -> LayoutDocument {
            LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: width,
            )
        }

        // MARK: - Readers

        private func measure(
            _ doc: LayoutDocument, _ index: Int,
        ) throws -> LayoutMeasure {
            for system in doc.systems {
                for m in system.measures where m.measureIndex == index {
                    return m
                }
            }
            throw TestFailure.notFound("measure \(index)")
        }

        private func keySignatures(
            _ m: LayoutMeasure,
        ) -> [(sharps: Int, flats: Int, naturals: [Int], origin: CGPoint)] {
            m.elements.compactMap { element in
                guard case let .keySignature(s, f, _, naturals, origin) = element
                else { return nil }
                return (s, f, naturals, origin)
            }
        }

        private func timeSignatures(
            _ m: LayoutMeasure,
        ) -> [(numerator: Int, denominator: Int, origin: CGPoint)] {
            m.elements.compactMap { element in
                guard case let .timeSignature(n, d, origin) = element
                else { return nil }
                return (n, d, origin)
            }
        }

        private func lastNoteheadX(_ m: LayoutMeasure) -> CGFloat {
            var maxX = -CGFloat.infinity
            for element in m.elements {
                guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _)
                    = element else { continue }
                for note in notes {
                    maxX = max(maxX, note.origin.x)
                }
            }
            return maxX
        }

        /// The system that contains `measureIndex`.
        private func system(
            _ doc: LayoutDocument, containing measureIndex: Int,
        ) throws -> LayoutSystem {
            for system in doc.systems
                where system.measures.contains(
                    where: { $0.measureIndex == measureIndex },
                )
            {
                return system
            }
            throw TestFailure.notFound("system containing \(measureIndex)")
        }

        // MARK: - Tests

        @Test("a break before a change announces key and time")
        func breakBeforeChangeEmitsCourtesyKeyAndTime() throws {
            let doc = layout(Self.score())
            // The break has to have happened, or there is nothing to
            // announce.
            #expect(doc.systems.count >= 2)
            #expect(try system(doc, containing: 1).measures.last?
                .measureIndex == 1)
            let m1 = try measure(doc, 1)
            let keys = keySignatures(m1)
            let times = timeSignatures(m1)
            #expect(keys.count == 1)
            #expect(times.count == 1)
            let key = try #require(keys.first)
            let time = try #require(times.first)
            #expect(key.flats == 2)
            #expect(key.sharps == 0)
            #expect(time.numerator == 3)
            #expect(time.denominator == 4)
            // Trailing: right of the measure's own content, and the time
            // signature right of the key signature.
            #expect(key.origin.x > lastNoteheadX(m1))
            #expect(time.origin.x > key.origin.x)
            // Inside the system it belongs to.
            let sys = try system(doc, containing: 1)
            #expect(m1.origin.x + time.origin.x < sys.size.width)
        }

        @Test("showCourtesy = false suppresses the announcement")
        func courtesyFlagOffEmitsNothing() throws {
            let doc = layout(Self.score(showCourtesy: false))
            let m1 = try measure(doc, 1)
            #expect(keySignatures(m1).isEmpty)
            #expect(timeSignatures(m1).isEmpty)
            // The change itself still renders inline in its own measure.
            #expect(try keySignatures(measure(doc, 2)).count == 1)
        }

        @Test("a mid-system change stays inline and announces nothing")
        func midSystemChangeIsNotAnnounced() throws {
            let doc = layout(
                Self.score(breakAfterM1: false), width: 2400,
            )
            #expect(doc.systems.count == 1)
            let m1 = try measure(doc, 1)
            #expect(keySignatures(m1).isEmpty)
            #expect(timeSignatures(m1).isEmpty)
            // Regression: the change is still drawn in the header column
            // of its own measure, left of that measure's first notehead.
            let m2 = try measure(doc, 2)
            let key = try #require(keySignatures(m2).first)
            #expect(keySignatures(m2).count == 1)
            #expect(key.flats == 2)
            var firstNoteX = CGFloat.infinity
            for element in m2.elements {
                guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _)
                    = element, let first = notes.first else { continue }
                firstNoteX = min(firstNoteX, first.origin.x)
            }
            #expect(key.origin.x < firstNoteX)
        }

        @Test("a courtesy of a change to C carries the naturals")
        func courtesyOfAChangeToCMajorCancels() throws {
            let doc = layout(
                Self.score(firstKey: 2, secondKey: 0, timeChange: nil),
            )
            let m1 = try measure(doc, 1)
            let key = try #require(keySignatures(m1).first)
            #expect(key.sharps == 0)
            #expect(key.flats == 0)
            // D major's F♯ C♯, at the treble positions.
            #expect(key.naturals == [4, 1])
            #expect(timeSignatures(m1).isEmpty)
        }

        @Test("every staff is announced, and the time signature once")
        func multiStaffAnnouncesEachKeyAndOneTime() throws {
            let doc = layout(Self.score(clefTypes: ["G", "F"]))
            let m1 = try measure(doc, 1)
            let keys = keySignatures(m1)
            #expect(keys.count == 2)
            #expect(keys.allSatisfy { $0.flats == 2 })
            // Two staves, one shared announcement column: both key
            // signatures at the same x, one time signature per staff at
            // the same x too.
            #expect(Set(keys.map(\.origin.x)).count == 1)
            let times = timeSignatures(m1)
            #expect(times.count == 2)
            #expect(Set(times.map(\.origin.x)).count == 1)
            // The two staves' announcements sit at different heights.
            #expect(Set(keys.map(\.origin.y)).count == 2)
        }

        @Test("breaking reserves the announcement's width")
        func systemDoesNotOverflowTheCourtesy() {
            // No explicit break: the width alone decides where the system
            // ends, so the packer has to reserve the announcement itself.
            let width: CGFloat = 420
            let doc = layout(
                Self.score(breakAfterM1: false), width: width,
            )
            #expect(doc.systems.count >= 2)
            // The scenario has to be live, or "nothing overflows" is
            // trivially true: some system must actually announce.
            var announced = 0
            for sys in doc.systems {
                #expect(sys.size.width <= width + 0.5)
                guard let last = sys.measures.last,
                      last.measureIndex != 2 else { continue }
                for element in last.elements {
                    guard let ink = inkSpan(of: element, sp: doc.metrics.sp)
                    else { continue }
                    announced += 1
                    #expect(last.origin.x + ink.right <= sys.size.width)
                    // Right of the end barline, per MuseScore's
                    // `EndBarLine, KeySigAnnounce, TimeSigAnnounce`
                    // trailer order.
                    #expect(ink.left > barLineX(last))
                }
            }
            #expect(announced > 0)
        }

        /// The announcement must fit as INK, not merely as an anchor
        /// point. A six- or seven-accidental modulation is where the
        /// difference bites: the header schedule's `sp * (glyphs + 1.5)`
        /// column is narrower than the `(glyphs - 1) * 1.4 sp + glyph`
        /// the renderer actually strides out, so sizing the courtesy that
        /// way put the last accidental past the system's right edge.
        /// The available width is deliberately narrow enough that
        /// `stretchWidths` is the identity — a stretched system scales the
        /// reservation up while the glyphs stay fixed, so slack from the
        /// stretch would hide an under-reservation.
        @Test(
            "a wide modulation's announcement fits inside the system",
            arguments: [
                // C -> G♭ major: six flats and no time change, so no
                // second column's slack can absorb the key's spill.
                (0, -6, nil as (Int, Int)?, 1 as Int),
                // C♯ -> C: seven naturals cancelling seven sharps.
                (7, 0, nil as (Int, Int)?, 1 as Int),
                // C♭ -> C: seven naturals cancelling seven flats.
                (-7, 0, nil as (Int, Int)?, 1 as Int),
                // Both columns, with a two-digit numerator.
                (0, -6, (12, 8) as (Int, Int)?, 2 as Int),
            ],
        )
        func wideModulationFitsInsideTheSystem(
            firstKey: Int,
            secondKey: Int,
            timeChange: (Int, Int)?,
            expectedAnnouncements: Int,
        ) throws {
            let doc = layout(
                Self.score(
                    firstKey: firstKey,
                    secondKey: secondKey,
                    timeChange: timeChange,
                ),
                width: 200,
            )
            let sys = try system(doc, containing: 1)
            let m1 = try measure(doc, 1)
            let barX = barLineX(m1)
            var announced = 0
            for element in m1.elements {
                guard let ink = inkSpan(of: element, sp: doc.metrics.sp),
                      // Only the trailing band; a system-head key
                      // signature that wrapping put on m1 is not one.
                      ink.left > barX
                else { continue }
                announced += 1
                // Both edges of the drawn ink, in system coordinates.
                #expect(m1.origin.x + ink.left >= 0)
                #expect(m1.origin.x + ink.right <= sys.size.width)
            }
            // If this drops, the fixture stopped exercising the wide case.
            #expect(announced == expectedAnnouncements)
        }

        /// Horizontal ink of a key / time signature element, measure-local.
        /// Mirrors what the renderers draw: `KeySignatureRenderer` strides
        /// accidentals by `KeySignatureSteps.advance` and centers each
        /// glyph on its stride; `TimeSignatureRenderer` does the same with
        /// `TimeSignatureLayout.digitAdvance`. `nil` for anything else.
        private func inkSpan(
            of element: LayoutElement, sp: CGFloat,
        ) -> (left: CGFloat, right: CGFloat)? {
            switch element {
            case let .keySignature(sharps, flats, _, naturals, origin):
                let count = naturals.count + sharps + flats
                guard count > 0 else { return nil }
                let half = KeySignatureSteps.glyphWidth(sp: sp) / 2
                let stride = KeySignatureSteps.advance(sp: sp)
                    * CGFloat(count - 1)
                return (origin.x - half, origin.x + stride + half)
            case let .timeSignature(numerator, denominator, origin):
                let digits = max(
                    String(numerator).count, String(denominator).count,
                )
                let half = TimeSignatureLayout.digitWidth(sp: sp) / 2
                let stride = TimeSignatureLayout.digitAdvance(sp: sp)
                    * CGFloat(digits - 1)
                return (origin.x - half, origin.x + stride + half)
            default:
                return nil
            }
        }

        /// The measure's own end barline. A measure that announces keeps
        /// it at the end of its CONTENT, not at its right edge.
        private func barLineX(_ m: LayoutMeasure) -> CGFloat {
            var maxX = -CGFloat.infinity
            for element in m.elements {
                guard case let .barLine(_, origin, _) = element
                else { continue }
                maxX = max(maxX, origin.x)
            }
            return maxX
        }

        /// The reservation itself, independent of where a break lands:
        /// a system ending at the measure before a change reserves the
        /// announcement's column; every other measure reserves nothing.
        @Test("the courtesy table reserves only at a change boundary")
        func courtesyTableWidths() throws {
            let metrics = StaffMetrics(staffSize: 28)
            let table = LayoutEngine.trailingCourtesies(
                staves: Self.score().allStaves.map(\.staff),
                metrics: metrics,
            )
            #expect(table.count == 4)
            #expect(table[0] == nil)
            #expect(table[2] == nil)
            #expect(table[3] == nil)
            let courtesy = try #require(table[1])
            // Gap, the two flats' ink, gap, the single digit's ink, and
            // the trailing pad — built from the renderers' own constants
            // rather than the header schedule's padded columns.
            let gap = metrics.sp * 0.5
            let keyInk = KeySignatureSteps.inkWidth(
                glyphCount: 2, sp: metrics.sp,
            )
            let timeInk = TimeSignatureLayout.inkWidth(
                numerator: 3, denominator: 4, sp: metrics.sp,
            )
            #expect(
                abs(courtesy.width - (gap + keyInk + gap + timeInk + gap))
                    < 0.0001,
            )
            // Every column's ink sits inside the reservation, with the
            // trailing pad to spare: the anchors are half a glyph in
            // because the renderers center each glyph on its stride.
            #expect(
                abs(
                    courtesy.keyOriginDx
                        - (gap + KeySignatureSteps.glyphWidth(sp: metrics.sp) / 2),
                ) < 0.0001,
            )
            #expect(
                courtesy.timeOriginDx
                    + timeInk
                    - TimeSignatureLayout.digitWidth(sp: metrics.sp) / 2
                    + gap <= courtesy.width + 0.0001,
            )
            #expect(courtesy.keys.count == 1)
            #expect(courtesy.time?.numerator == 3)
        }
    }

    // MARK: - Staff-line extent

    /// The staff lines' right edge at an announcing system boundary. A
    /// separate extension so the suite's body stays inside the repository's
    /// `type_body_length` budget; Swift Testing collects `@Test` functions
    /// from extensions just as it does from the type body.
    extension CourtesySignatureLayoutTests {
        @Test("a courtesy key uses a double synthesized end barline")
        func courtesyKeyUsesDoubleEndBarLine() throws {
            let doc = layout(Self.score())
            let sys = try system(doc, containing: 1)
            let m1 = try measure(doc, 1)
            let barX = barLineX(m1)
            #expect(sys.trailingBarLine?.subtype == "double")
            #expect(m1.elements.contains { element in
                guard case let .barLine(subtype, origin, _) = element
                else { return false }
                return origin.x == barX && subtype == "double"
            })
        }

        @Test("a time-only courtesy keeps a single end barline")
        func timeOnlyCourtesyKeepsSingleEndBarLine() throws {
            let doc = layout(
                Self.score(
                    firstKey: 0,
                    secondKey: 0,
                    timeChange: (3, 4),
                ),
            )
            let sys = try system(doc, containing: 1)
            let m1 = try measure(doc, 1)
            let barX = barLineX(m1)
            let trailingKeys = keySignatures(m1).filter {
                $0.origin.x > barX
            }
            let trailingTimes = timeSignatures(m1).filter {
                $0.origin.x > barX
            }
            #expect(trailingKeys.isEmpty)
            #expect(trailingTimes.count == 1)
            #expect(sys.trailingBarLine?.subtype == nil)
        }

        @Test("a mid-system key change keeps a single preceding barline")
        func midSystemKeyChangeKeepsSinglePrecedingBarLine() throws {
            let doc = layout(
                Self.score(breakAfterM1: false), width: 2400,
            )
            #expect(doc.systems.count == 1)
            let m1 = try measure(doc, 1)
            let barX = barLineX(m1)
            var foundRightmostBar = false
            var rightmostSubtype: String?
            for element in m1.elements {
                guard case let .barLine(subtype, origin, _) = element,
                      origin.x == barX else { continue }
                foundRightmostBar = true
                rightmostSubtype = subtype
            }
            #expect(foundRightmostBar)
            #expect(rightmostSubtype == nil)
        }

        @Test(
            "staff lines cover each trailing courtesy signature",
            arguments: [
                (-2, (3, 4) as (Int, Int)?, 900 as CGFloat, 2),
                (-6, nil as (Int, Int)?, 200 as CGFloat, 1),
            ],
        )
        func staffLinesCoverTrailingCourtesySignatures(
            secondKey: Int,
            timeChange: (Int, Int)?,
            width: CGFloat,
            expectedAnnouncements: Int,
        ) throws {
            let doc = layout(
                Self.score(
                    firstKey: 0,
                    secondKey: secondKey,
                    timeChange: timeChange,
                ),
                width: width,
            )
            let sys = try system(doc, containing: 1)
            let m1 = try measure(doc, 1)
            let barX = barLineX(m1)
            let bar = try #require(sys.trailingBarLine)
            let barEnd = bar.x + BarLineGeometry.rightExtent(
                subtype: bar.subtype, sp: sys.sp,
            )
            let endX = BarLineGeometry.staffLineEndX(for: sys)
            var announced = 0
            var maxInkRight = -CGFloat.infinity
            for element in m1.elements {
                let originX: CGFloat
                switch element {
                case let .keySignature(_, _, _, _, origin),
                     let .timeSignature(_, _, origin):
                    originX = origin.x
                default:
                    continue
                }
                guard originX > barX else { continue }
                let ink = try #require(inkSpan(of: element, sp: sys.sp))
                announced += 1
                maxInkRight = max(maxInkRight, m1.origin.x + ink.right)
                #expect(endX >= m1.origin.x + ink.right)
            }
            #expect(announced == expectedAnnouncements)
            // The band closes with one trailing gap after its last column, so
            // the staff lines stop exactly `sp * 0.5` past the rightmost glyph's
            // ink. Pinning that distance — rather than restating
            // `staffLineEndX`'s own formula — is what would catch a mis-sized
            // reservation.
            #expect(abs(endX - maxInkRight - sys.sp * 0.5) < 0.0001)
            #expect(endX > barEnd)
        }

        @Test("a plain system end keeps the terminal-barline clip")
        func plainSystemEndKeepsTerminalBarLineClip() throws {
            let doc = layout(Self.score(showCourtesy: false))
            let sys = try system(doc, containing: 1)
            let m1 = try measure(doc, 1)
            #expect(sys.measures.last?.measureIndex == m1.measureIndex)
            let bar = try #require(sys.trailingBarLine)
            // Suppressing the announcement also guards that the synthesized
            // end barline is not upgraded to a courtesy-key double.
            #expect(bar.subtype == nil)
            let endX = BarLineGeometry.staffLineEndX(for: sys)
            let expected = bar.x + BarLineGeometry.rightExtent(
                subtype: bar.subtype, sp: sys.sp,
            )
            #expect(endX == expected)
            #expect(endX < sys.size.width)
        }

        @Test("one staff-line end covers every staff's announcement")
        func sharedStaffLineEndCoversAllStaves() throws {
            let doc = layout(Self.score(clefTypes: ["G", "F"]))
            let sys = try system(doc, containing: 1)
            let m1 = try measure(doc, 1)
            let barX = barLineX(m1)
            let endX = BarLineGeometry.staffLineEndX(for: sys)
            var announced = 0
            var maxInkRight = -CGFloat.infinity
            var staffYs: Set<CGFloat> = []
            for element in m1.elements {
                let origin: CGPoint
                switch element {
                case let .keySignature(_, _, _, _, value),
                     let .timeSignature(_, _, value):
                    origin = value
                default:
                    continue
                }
                guard origin.x > barX else { continue }
                let ink = try #require(inkSpan(of: element, sp: sys.sp))
                announced += 1
                staffYs.insert(origin.y)
                maxInkRight = max(maxInkRight, m1.origin.x + ink.right)
                #expect(endX >= m1.origin.x + ink.right)
            }
            // The band closes with one trailing gap after its last column, so
            // the staff lines stop exactly `sp * 0.5` past the rightmost glyph's
            // ink. Pinning that distance — rather than restating
            // `staffLineEndX`'s own formula — is what would catch a mis-sized
            // reservation.
            #expect(abs(endX - maxInkRight - sys.sp * 0.5) < 0.0001)
            #expect(announced == 4)
            #expect(staffYs.count == 2)
        }
    }
#endif
