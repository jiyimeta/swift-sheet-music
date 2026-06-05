import Foundation
@testable import SheetMusicAudioCore
import Testing

struct MasterTuningTests { // swiftlint:disable:this inclusive_language
    @Test func splitZeroCents() {
        let s = MasterTuning.split(cents: 0)
        #expect(s.coarseSemitones == 0)
        #expect(abs(s.fineCents) < 1e-9)
    }

    @Test func split432() {
        // 432 Hz ≈ -31.77¢ → coarse 0, fine ≈ -31.77
        let cents = 1200 * log2(432.0 / 440.0)
        let s = MasterTuning.split(cents: cents)
        #expect(s.coarseSemitones == 0)
        #expect(abs(s.fineCents - cents) < 1e-6)
    }

    @Test func split415IsOneSemitoneDown() {
        // 415 Hz ≈ -100.7¢ → coarse -1, fine small (|fine| ≤ 50)
        let cents = 1200 * log2(415.0 / 440.0)
        let s = MasterTuning.split(cents: cents)
        #expect(s.coarseSemitones == -1)
        #expect(abs(s.fineCents) <= 50)
        // round-trips: coarse*100 + fine == cents
        #expect(abs(Double(s.coarseSemitones) * 100 + s.fineCents - cents) < 1e-6)
    }

    @Test func split466IsOneSemitoneUp() {
        let cents = 1200 * log2(466.0 / 440.0)
        let s = MasterTuning.split(cents: cents)
        #expect(s.coarseSemitones == 1)
        #expect(abs(s.fineCents) <= 50)
    }

    @Test func rpnZeroCentsIsCentered() {
        let m = MasterTuning.rpnControlChanges(cents: 0)
        #expect(m == [
            MasterTuning.CC(controller: 101, value: 0), MasterTuning.CC(controller: 100, value: 2),
            MasterTuning.CC(controller: 6, value: 64), MasterTuning.CC(controller: 38, value: 0),
            MasterTuning.CC(controller: 101, value: 0), MasterTuning.CC(controller: 100, value: 1),
            MasterTuning.CC(controller: 6, value: 64), MasterTuning.CC(controller: 38, value: 0),
            MasterTuning.CC(controller: 101, value: 127), MasterTuning.CC(controller: 100, value: 127),
        ])
    }

    @Test func rpn432FineIsFlat() {
        let cents = 1200 * log2(432.0 / 440.0)
        let m = MasterTuning.rpnControlChanges(cents: cents)
        // coarse data-entry MSB stays centered at 64 (no whole-semitone shift)
        #expect(m[2] == MasterTuning.CC(controller: 6, value: 64))
        // fine data-entry MSB (the 7th element, index 6) is below center → flat
        #expect(m[6].controller == 6 && m[6].value < 64)
    }

    @Test func rpn415CoarseIsDown() {
        let cents = 1200 * log2(415.0 / 440.0)
        let m = MasterTuning.rpnControlChanges(cents: cents)
        #expect(m[2] == MasterTuning.CC(controller: 6, value: 63)) // 64 + (-1)
    }
}
