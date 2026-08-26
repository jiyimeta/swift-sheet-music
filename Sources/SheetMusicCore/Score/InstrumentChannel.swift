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
    }
}
