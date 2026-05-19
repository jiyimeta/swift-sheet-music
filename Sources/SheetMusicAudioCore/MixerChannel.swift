import Foundation

/// One strip in the mixer — a per-staff channel or the metronome.
/// The host app reads the array to render UI and calls
/// `PlaybackEngine.setVolume / setMuted / setSoloed` to mutate.
///
/// "Effective" mute follows standard mixer convention: when *any*
/// channel is soloed, every non-soloed channel is silenced. Solo
/// is therefore inclusive — multiple channels can solo at once and
/// they'll all be heard, while non-soloed channels go quiet.
public struct MixerChannel: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case staff(Int)
        case metronome
    }

    public let id: Kind
    public let name: String
    /// Linear gain. 0 = silent, 1 = unity. The slider passes this
    /// straight to `AVAudioUnit.volume`, which is also linear.
    public var volume: Float
    public var isMuted: Bool
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
}
