#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// Cancellation naturals: a key change that lands on C (zero
/// accidentals) draws the OUTGOING key's accidentals as naturals, in
/// that key's own order, and nothing else. Every other change draws
/// only the new signature.
@Suite("Cancellation naturals")
struct CancellationNaturalStepsTests {
    @Test func naturalStepsCancellingThreeSharpsAreAMajorsPositions() {
        // A major's F♯ C♯ G♯, in sharp order, at the treble positions.
        #expect(
            KeySignatureSteps.naturalSteps(cancelling: 3, clef: .treble)
                == [4, 1, 5],
        )
    }

    @Test func naturalStepsCancellingFlatsUseTheFlatOrder() {
        // E♭ major's B♭ E♭ A♭.
        #expect(
            KeySignatureSteps.naturalSteps(cancelling: -3, clef: .treble)
                == [0, 3, -1],
        )
    }

    @Test func naturalStepsFollowTheClefInForce() {
        #expect(
            KeySignatureSteps.naturalSteps(cancelling: 2, clef: .bass)
                == [2, -1],
        )
    }

    @Test func nothingToCancelUnderCMajor() {
        #expect(
            KeySignatureSteps.naturalSteps(cancelling: 0, clef: .treble)
                .isEmpty,
        )
    }

    @Test func cancellationOnlyAppliesWhenTheNewKeyIsCMajor() {
        // D → C cancels D's two sharps.
        #expect(
            KeySignatureSteps.cancellationNaturals(
                priorKey: 2, newKey: 0, clef: .treble,
            ) == [4, 1],
        )
        // G → D draws only the new signature.
        #expect(
            KeySignatureSteps.cancellationNaturals(
                priorKey: 1, newKey: 2, clef: .treble,
            ).isEmpty,
        )
        // C → C has nothing to cancel.
        #expect(
            KeySignatureSteps.cancellationNaturals(
                priorKey: 0, newKey: 0, clef: .treble,
            ).isEmpty,
        )
        // C → G is a plain signature.
        #expect(
            KeySignatureSteps.cancellationNaturals(
                priorKey: 0, newKey: 3, clef: .treble,
            ).isEmpty,
        )
    }
}

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    @Suite("Cancellation naturals layout")
    struct CancellationNaturalsLayoutTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        /// Two bars on one treble staff: bar 0 opens in `firstKey`, bar 1
        /// opens with an explicit change to `secondKey`.
        private func twoBarScore(
            firstKey: Int,
            secondKey: Int,
            showCourtesy: Bool = true,
        ) -> Score {
            func chord() -> VoiceElement {
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                ))
            }
            var change = KeySignature(concertKey: secondKey)
            change.showCourtesy = showCourtesy
            let bar0 = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .keySignature(KeySignature(concertKey: firstKey)),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                chord(),
            ])])
            let bar1 = Measure(voices: [Voice(elements: [
                .keySignature(change),
                chord(),
            ])])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: [bar0, bar1])],
                )],
            )
        }

        private func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 900,
            )
        }

        private func elements(
            _ doc: LayoutDocument, measure index: Int,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .filter { $0.measureIndex == index }
                .flatMap(\.elements)
        }

        /// The key-signature element laid out inside measure `index`.
        private func keySignature(
            _ doc: LayoutDocument, measure index: Int,
        ) throws -> (
            sharps: Int, flats: Int, naturals: [Int], origin: CGPoint,
        ) {
            for element in elements(doc, measure: index) {
                if case let .keySignature(s, f, _, naturals, origin) = element {
                    return (s, f, naturals, origin)
                }
            }
            throw TestFailure.notFound("key signature in measure \(index)")
        }

        private func firstNoteheadX(
            _ doc: LayoutDocument, measure index: Int,
        ) throws -> CGFloat {
            for element in elements(doc, measure: index) {
                if case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element,
                   let first = notes.first
                {
                    return first.origin.x
                }
            }
            throw TestFailure.notFound("chord in measure \(index)")
        }

        enum TestFailure: Error { case notFound(String) }

        @Test func changeToCMajorDrawsTheOutgoingSharpsAsNaturals() throws {
            let doc = layout(twoBarScore(firstKey: 1, secondKey: 0))
            let sig = try keySignature(doc, measure: 1)
            #expect(sig.sharps == 0)
            #expect(sig.flats == 0)
            #expect(sig.naturals == [4])
        }

        @Test func changeToCMajorFromFlatsCancelsAtTheFlatPositions() throws {
            let doc = layout(twoBarScore(firstKey: -3, secondKey: 0))
            let sig = try keySignature(doc, measure: 1)
            #expect(sig.naturals == [0, 3, -1])
            #expect(sig.flats == 0)
        }

        @Test func aChangeToAnotherKeyDrawsOnlyTheNewSignature() throws {
            let doc = layout(twoBarScore(firstKey: 1, secondKey: 2))
            let sig = try keySignature(doc, measure: 1)
            #expect(sig.sharps == 2)
            #expect(sig.naturals.isEmpty)
        }

        @Test func theLeadingSignatureNeverCancels() throws {
            let doc = layout(twoBarScore(firstKey: 1, secondKey: 0))
            let sig = try keySignature(doc, measure: 0)
            #expect(sig.sharps == 1)
            #expect(sig.naturals.isEmpty)
        }

        /// Naturals describe the inline signature, not the courtesy one:
        /// suppressing the courtesy must not suppress them.
        @Test func courtesySuppressionLeavesTheNaturalsAlone() throws {
            let doc = layout(
                twoBarScore(firstKey: 2, secondKey: 0, showCourtesy: false),
            )
            let sig = try keySignature(doc, measure: 1)
            #expect(sig.naturals == [4, 1])
        }

        /// The naturals occupy the key-signature column, so the measure's
        /// content has to start clear of them.
        @Test func contentStartsClearOfTheNaturals() throws {
            let doc = layout(twoBarScore(firstKey: 3, secondKey: 0))
            let sig = try keySignature(doc, measure: 1)
            let noteX = try firstNoteheadX(doc, measure: 1)
            let advance = KeySignatureSteps.advance(sp: doc.metrics.sp)
            #expect(noteX >= sig.origin.x + advance * 3)
        }

        /// Header scheduling: a change to C that cancels three sharps
        /// reserves the same column width three sharps would have.
        @Test func headerScheduleReservesTheNaturalsAdvance() {
            let staves = twoBarScore(firstKey: 3, secondKey: 0)
                .allStaves.map(\.staff)
            let metrics = StaffMetrics(staffSize: 28)
            let cancelling = LayoutEngine.computeHeaderSchedule(
                measureIdx: 1,
                staves: staves,
                metrics: metrics,
                synthesizeClefForAllStaves: false,
                activeKeys: [3],
            )
            let plain = LayoutEngine.computeHeaderSchedule(
                measureIdx: 1,
                staves: staves,
                metrics: metrics,
                synthesizeClefForAllStaves: false,
                activeKeys: [0],
            )
            #expect(
                cancelling.timeSigX - cancelling.keySigX == metrics.sp * 4.5,
            )
            #expect(plain.timeSigX - plain.keySigX == metrics.sp * 1.5)
        }

        /// The per-measure width pass is deliberately blind to the
        /// preceding measures, so the naturals' advance is added on top
        /// of it — the way `synthHeaderOverhead` does for a system head.
        @Test func measureWidthsCarryTheCancellationBoost() {
            let metrics = StaffMetrics(staffSize: 28)
            let boosts = LayoutEngine.cancellationNaturalWidths(
                staves: twoBarScore(firstKey: 3, secondKey: 0)
                    .allStaves.map(\.staff),
                metrics: metrics,
            )
            #expect(boosts == [0, metrics.sp * 3])
            let none = LayoutEngine.cancellationNaturalWidths(
                staves: twoBarScore(firstKey: 1, secondKey: 2)
                    .allStaves.map(\.staff),
                metrics: metrics,
            )
            #expect(none == [0, 0])
        }
    }
#endif
