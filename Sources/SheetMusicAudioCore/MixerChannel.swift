import SheetMusicFoundation

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
    /// Self-sufficient label for a flat list of strips: the part, plus
    /// the instrument in parentheses when the part has more than one.
    /// `LiveChannelPlan.labels(for:in:)` composes it.
    public let name: String
    /// The part this strip belongs to, for a host that groups its strips
    /// and titles each group. Empty for the metronome, which belongs to
    /// no part.
    public let partName: String
    /// The instrument driving this strip, unqualified by the part — the
    /// row label under such a group title. `nil` for the metronome,
    /// whose sound is fixed.
    ///
    /// Reported even when `name` suppresses it (a part named after its
    /// own instrument): what a host draws is its own decision, and
    /// re-splitting `name` on its parentheses would fail on exactly
    /// those strips.
    public let instrumentName: String?
    /// Linear gain. 0 = silent, 1 = unity. The slider passes this
    /// straight to `AVAudioUnit.volume`, which is also linear.
    public var volume: Float
    public var isMuted: Bool
    /// Ignored unless `isSoloable` — `PlaybackEngine.setSoloed` refuses
    /// to raise it on a strip that isn't on the solo bus, so it stays
    /// `false` on the metronome however a host drives the engine.
    public var isSoloed: Bool
    /// GM program (0...127) currently driving the strip. On a drum strip
    /// this is the KIT — a program number in bank 128 — which is why it
    /// is reported rather than hidden: the kit is selectable, and a host
    /// that offers a picker needs to know which one is loaded.
    /// `nil` only for the metronome, whose sound is fixed (Hi/Low Wood
    /// Block) and whose picker stays hidden.
    public var program: UInt8?
    /// Whether this strip plays a drum kit, so a host offers the drum
    /// catalog rather than the melodic one. `false` for the metronome,
    /// which offers neither.
    public let isDrums: Bool

    public init(
        id: Kind,
        name: String,
        partName: String = "",
        instrumentName: String? = nil,
        volume: Float = 1.0,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        program: UInt8? = nil,
        isDrums: Bool = false,
    ) {
        self.id = id
        self.name = name
        self.partName = partName
        self.instrumentName = instrumentName
        self.isDrums = isDrums
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
