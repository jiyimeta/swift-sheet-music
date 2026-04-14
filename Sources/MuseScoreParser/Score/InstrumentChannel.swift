import Foundation

/// A MIDI channel assignment for one playback flavor of an instrument
/// ("normal", "pizzicato", etc.). C++: `mu::engraving::InstrChannel` (subset).
public struct InstrumentChannel: Sendable, Equatable {
    public var name: String?
    public var program: Int
    public var bank: Int
    public var volume: Int
    public var pan: Int
    public var reverb: Int
    public var chorus: Int

    public init(
        name: String? = nil,
        program: Int = 0,
        bank: Int = 0,
        volume: Int = 100,
        pan: Int = 64,
        reverb: Int = 0,
        chorus: Int = 0
    ) {
        self.name = name
        self.program = program
        self.bank = bank
        self.volume = volume
        self.pan = pan
        self.reverb = reverb
        self.chorus = chorus
    }
}
