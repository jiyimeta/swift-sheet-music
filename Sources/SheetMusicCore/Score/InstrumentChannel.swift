import SheetMusicFoundation

/// A MIDI channel assignment for one playback flavor of an instrument
/// ("normal", "pizzicato", etc.). C++: `mu::engraving::InstrChannel` (subset).
public struct InstrumentChannel: Sendable, Equatable, Hashable {
    public var name: String?
    public var program: Int
    public var bank: Int
    public var volume: Int
    public var pan: Int
    public var reverb: Int
    public var chorus: Int
    /// Explicit MIDI channel from `<midiChannel>`. nil means "use the default
    /// (= staff index)" assigned by the renderer.
    public var midiChannel: Int?
    /// Explicit MIDI port from `<midiPort>`. nil means port 0.
    public var midiPort: Int?
    /// Source markup under this element that the model does not
    /// represent, kept so that read → write does not delete it.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        name: String? = nil,
        program: Int = 0,
        bank: Int = 0,
        volume: Int = 100,
        pan: Int = 64,
        reverb: Int = 0,
        chorus: Int = 0,
        midiChannel: Int? = nil,
        midiPort: Int? = nil,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.name = name
        self.program = program
        self.bank = bank
        self.volume = volume
        self.pan = pan
        self.reverb = reverb
        self.chorus = chorus
        self.midiChannel = midiChannel
        self.midiPort = midiPort
        self.preservedMarkup = preservedMarkup
    }

    /// Hashes the modeled playback state. Inert preserved markup is
    /// excluded; unequal values may share a hash, while equal values
    /// still always produce the same hash as `Hashable` requires.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(program)
        hasher.combine(bank)
        hasher.combine(volume)
        hasher.combine(pan)
        hasher.combine(reverb)
        hasher.combine(chorus)
        hasher.combine(midiChannel)
        hasher.combine(midiPort)
    }
}
