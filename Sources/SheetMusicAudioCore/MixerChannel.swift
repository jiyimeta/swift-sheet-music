import Foundation

/// One strip in the mixer — a per-(part × instrument) channel or the
/// metronome. The host app reads the array to render UI and calls
/// `PlaybackEngine.setVolume / setMuted / setSoloed` to mutate.
///
/// "Effective" mute follows standard mixer convention: when *any*
/// soloable channel is soloed, every non-soloed soloable channel is
/// silenced. Solo is therefore inclusive — multiple channels can solo
/// at once and they'll all be heard, while non-soloed ones go quiet.
///
/// **The metronome sits outside the solo bus** (`isSoloable == false`),
/// the way a DAW's click does. It is a reference track, not a part of
/// the mix: soloing an instrument to practise against it must not take
/// the click with it, and the metronome cannot silence the instruments
/// either. Its own `isMuted` — what a host's metronome toggle writes —
/// stays the only thing that turns it off.
public struct MixerChannel: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// `ordinal` indexes the part's DEDUPED instruments in
        /// first-appearance order (`LiveChannelPlan.Strip.ordinal`), so
        /// it is stable for a given score and matches the live channel
        /// set one-to-one. Replaced `case staff(Int)`: a multi-staff
        /// part shared one channel, so per-staff strips were duplicates,
        /// and a part that changes instrument needs more than one strip.
        case instrument(partIndex: Int, ordinal: Int)
        case metronome
    }

    public let id: Kind
    public let name: String
    /// Linear gain. 0 = silent, 1 = unity. The slider passes this
    /// straight to `AVAudioUnit.volume`, which is also linear.
    public var volume: Float
    public var isMuted: Bool
    /// Ignored unless `isSoloable` — `PlaybackEngine.setSoloed` refuses
    /// to raise it on a strip that isn't on the solo bus, so it stays
    /// `false` on the metronome however a host drives the engine.
    public var isSoloed: Bool
    /// GM program (0...127) currently driving the staff sampler.
    /// `nil` for the metronome strip — its sound is fixed (Hi/Low
    /// Wood Block) and the picker is hidden in the UI.
    public var program: UInt8?

    public init(
        id: Kind,
        name: String,
        volume: Float = 1.0,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        program: UInt8? = nil,
    ) {
        self.id = id
        self.name = name
        self.volume = volume
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.program = program
    }

    /// Whether this strip is on the solo bus. `false` for the metronome
    /// — see the type doc. Hosts hide the solo control on a strip that
    /// returns `false`, the same way `program == nil` hides the program
    /// picker; the engine enforces the rule regardless.
    public var isSoloable: Bool {
        if case .instrument = id { true } else { false }
    }
}
