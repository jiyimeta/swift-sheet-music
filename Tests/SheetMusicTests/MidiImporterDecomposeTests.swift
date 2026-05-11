import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Direct tests for `MidiImporter.decomposeIntoStandardDurations` —
/// the rhythm-decomposition core that turns an arbitrary tick gap
/// at a given measure-relative offset into a sequence of standard
/// `NoteDuration` values.
struct MidiImporterDecomposeTests {
    @Test func tripleDottedHalfTickCountSplitsIntoFourBeatAlignedParts() {
        // 1800 ticks (= triple-dotted half) at offset 0. With
        // maxDots=0, decompose greedily into binary durations to
        // give [half, quarter, eighth, sixteenth].
        let parts = MidiImporter.decomposeIntoStandardDurations(
            ticks: 1800, division: 480, offsetInMeasure: 0, maxDots: 0,
        )
        #expect(parts == [.half, .quarter, .eighth, .sixteenth])
    }

    @Test func dottedEighthChordSplitsAtBeatBoundaryWhenCrossing() {
        // User-reported case: a dotted-eighth at offset 840 in 4/4
        // crosses the beat 3 boundary at 960. Must split into
        // [16th, eighth] (tied).
        let parts = MidiImporter.decomposeIntoStandardDurations(
            ticks: 360, division: 480, offsetInMeasure: 840, maxDots: 1,
        )
        #expect(parts == [.sixteenth, .eighth])
    }

    @Test func dottedQuarterAtBeat1IsPreservedAsSingleElement() {
        // At a beat-aligned offset (0), a dotted-quarter chord
        // stays a single dotted quarter.
        let parts = MidiImporter.decomposeIntoStandardDurations(
            ticks: 720, division: 480, offsetInMeasure: 0, maxDots: 1,
        )
        #expect(parts == [NoteDuration.quarter.dotted(1)])
    }

    @Test func longHeldChordSplitsAtHalfMeasureBoundary() {
        // 1680-tick held chord at offset 240 in 4/4 splits into
        // [dotted-quarter, half] (tied). The dotted-quarter ends
        // exactly at the half-measure boundary (960) — accepted by
        // the end-aligned clause of `metricallyAligned`.
        let parts = MidiImporter.decomposeIntoStandardDurations(
            ticks: 1680, division: 480, offsetInMeasure: 240, maxDots: 1,
        )
        let dottedQuarter = NoteDuration.fraction(Fraction(numerator: 3, denominator: 8))
        #expect(parts == [dottedQuarter, .half])
    }

    @Test func doubleDottedHalfChordPreservedWhenMaxDotsIsTwo() {
        // 1680 ticks at offset 0 = double-dotted half (7/8). With
        // maxDots=1 the decomposer uses dotted-half + eighth; with
        // maxDots=2 it collapses to one double-dotted half.
        let single = MidiImporter.decomposeIntoStandardDurations(
            ticks: 1680, division: 480, offsetInMeasure: 0, maxDots: 1,
        )
        #expect(single == [NoteDuration.half.dotted(1), .eighth])
        let double = MidiImporter.decomposeIntoStandardDurations(
            ticks: 1680, division: 480, offsetInMeasure: 0, maxDots: 2,
        )
        #expect(double == [NoteDuration.half.dotted(2)])
    }

    @Test func tripleDottedFormsRequireMaxDotsThree() {
        // 1800 ticks at offset 0 = triple-dotted half (15/16).
        // maxDots=2 still splits; maxDots=3 collapses.
        let double = MidiImporter.decomposeIntoStandardDurations(
            ticks: 1800, division: 480, offsetInMeasure: 0, maxDots: 2,
        )
        #expect(double == [NoteDuration.half.dotted(2), .sixteenth])
        let triple = MidiImporter.decomposeIntoStandardDurations(
            ticks: 1800, division: 480, offsetInMeasure: 0, maxDots: 3,
        )
        #expect(triple == [NoteDuration.half.dotted(3)])
    }
}
