#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct PDFImporterTupletApplyTests {
        static func note(
            _ duration: NoteDuration, x: CGFloat, pitch: Int = 60,
        ) -> RhythmElement {
            RhythmElement(
                chord: Chord(
                    duration: duration,
                    notes: [Note(pitch: pitch, tpc: 14)],
                ),
                x: x, y: 0,
            )
        }

        static func rest(_ duration: NoteDuration, x: CGFloat) -> RhythmElement {
            RhythmElement(
                chord: Chord(duration: duration, notes: []),
                x: x, y: 0,
            )
        }

        static func mark(
            _ range: ClosedRange<CGFloat>,
            anchor: PDFImporter.TupletMark.Anchor = .bracket,
            digitCenterX: CGFloat? = nil,
        ) -> PDFImporter.TupletMark {
            PDFImporter.TupletMark(
                xRange: range,
                normal: 2, actual: 3,
                digitCenterX: digitCenterX ?? (range.lowerBound + range.upperBound) / 2,
                digitOrigin: .zero,
                anchor: anchor,
            )
        }

        /// 君とParadiso p0 m0: a bracketed triplet quarter + eighth. The
        /// members are NOT equal and NOT beamed, which is exactly what the
        /// old run-based detector could never see.
        @Test func bracketScalesHeterogeneousMembers() {
            let elements = [
                Self.note(.half, x: 109.5),
                Self.note(.quarter, x: 176.6),
                Self.note(.eighth, x: 200.4),
            ]
            let out = PDFImporter.applyTupletMarks(
                elements: elements,
                marks: [Self.mark(178.2 ... 206.4)],
                spatium: 3.35,
            )
            #expect(out[0].chord.duration == .half)
            #expect(out[0].inTuplet == false)
            #expect(out[1].chord.duration == .fraction(
                Fraction(numerator: 1, denominator: 6),
            ))
            #expect(out[2].chord.duration == .fraction(
                Fraction(numerator: 1, denominator: 12),
            ))
            #expect(out[1].inTuplet)
            #expect(out[2].inTuplet)
        }

        /// A run whose scaled sum is not a clean note value is not a
        /// tuplet: two straight eighths scale to 1/6, which no written
        /// value spells.
        @Test func unscalableRunIsLeftAlone() {
            let elements = [
                Self.note(.eighth, x: 100),
                Self.note(.eighth, x: 120),
            ]
            let out = PDFImporter.applyTupletMarks(
                elements: elements,
                marks: [Self.mark(95 ... 125)],
                spatium: 5,
            )
            #expect(out[0].chord.duration == .eighth)
            #expect(out[1].chord.duration == .eighth)
            #expect(out.allSatisfy { !$0.inTuplet })
        }

        /// A bracket may enclose a rest; it is a member and scales too.
        @Test func restInsideABracketIsAMember() {
            let elements = [
                Self.note(.eighth, x: 100),
                Self.rest(.eighth, x: 120),
                Self.note(.eighth, x: 140),
            ]
            let out = PDFImporter.applyTupletMarks(
                elements: elements,
                marks: [Self.mark(95 ... 145)],
                spatium: 5,
            )
            let twelfth = NoteDuration.fraction(
                Fraction(numerator: 1, denominator: 12),
            )
            #expect(out.allSatisfy { $0.chord.duration == twelfth })
            #expect(out.allSatisfy { $0.inTuplet == true })
        }

        /// Now_is_the_time p4 m91: the beam window holds five sixteenths
        /// but only the first three are the triplet. Runs of two (1/12) and
        /// four (1/6) fail the clean-sum gate; the three-note run wins.
        @Test func beamWindowPicksTheCleanRunNearestTheDigit() {
            let xs: [CGFloat] = [453.9, 459.1, 464.3, 469.4, 476.4]
            let elements = xs.map { Self.note(.sixteenth, x: $0) }
            let out = PDFImporter.applyTupletMarks(
                elements: elements,
                marks: [Self.mark(
                    457.3 ... 467.9, anchor: .beam, digitCenterX: 462.59,
                )],
                spatium: 2.83,
            )
            let twentyFourth = NoteDuration.fraction(
                Fraction(numerator: 1, denominator: 24),
            )
            #expect(out[0].chord.duration == twentyFourth)
            #expect(out[1].chord.duration == twentyFourth)
            #expect(out[2].chord.duration == twentyFourth)
            #expect(out[3].chord.duration == .sixteenth)
            #expect(out[4].chord.duration == .sixteenth)
        }
    }
#endif
