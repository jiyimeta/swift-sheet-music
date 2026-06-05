import Foundation

/// A4 master-tuning math shared by the Apple and Android playback engines.
///
/// A cents offset from A4=440 is split into a whole-semitone "coarse" part and a
/// remaining "fine" part. iOS feeds the split straight into the AUMIDISynth's
/// global AudioUnit tuning params (id 901 Coarse / 902 Fine); Android turns it
/// into the MIDI Master Tuning RPN that FluidSynth honors. Keeping the split here
/// gives both platforms one source of truth.
public enum MasterTuning { // swiftlint:disable:this inclusive_language
    /// Split a cents offset (relative to A4=440) into nearest-semitone coarse +
    /// remaining fine cents. `coarse*100 + fine == cents`, with `|fine| ≤ 50`.
    public static func split(cents: Double) -> (coarseSemitones: Int, fineCents: Double) {
        let coarse = Int((cents / 100).rounded())
        return (coarse, cents - 100 * Double(coarse))
    }

    /// One MIDI Control-Change message (controller + 7-bit value).
    public struct CC: Equatable, Sendable {
        public let controller: UInt8
        public let value: UInt8
        public init(controller: UInt8, value: UInt8) {
            self.controller = controller
            self.value = value
        }
    }

    /// CC pairs to send (in order) to one channel so an RPN-honoring synth
    /// (e.g. FluidSynth) retunes by `cents`. Both data-entry bytes are emitted
    /// per RPN so 14-bit-strict synths apply the value.
    public static func rpnControlChanges(cents: Double) -> [CC] {
        let (coarse, fineCents) = split(cents: cents)
        let fine14 = max(0, min(16383, 8192 + Int((fineCents / 100 * 8192).rounded())))
        let coarseValue = UInt8(max(0, min(127, 64 + coarse)))
        return [
            CC(controller: 101, value: 0), CC(controller: 100, value: 2),
            CC(controller: 6, value: coarseValue), CC(controller: 38, value: 0),
            CC(controller: 101, value: 0), CC(controller: 100, value: 1),
            CC(controller: 6, value: UInt8(fine14 >> 7)), CC(controller: 38, value: UInt8(fine14 & 0x7F)),
            CC(controller: 101, value: 127), CC(controller: 100, value: 127),
        ]
    }
}
