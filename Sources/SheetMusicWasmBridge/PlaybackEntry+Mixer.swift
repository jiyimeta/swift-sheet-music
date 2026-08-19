import JavaScriptKit
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMIDI

/// One mixer strip: a deduped (part × instrument) pair and the live MIDI
/// channel its program, volume and mute have to be routed through.
///
/// **The host must assert `program` and `volume` itself before playing.** The
/// sequence `renderMidi` produces deliberately carries neither on a
/// mixer-managed channel — `MidiSynthPostProcess` strips the tick-0 program and
/// CC 7 so a backward seek cannot replay them over a live override. Apple and
/// Android both re-assert from their mixer after every start; a web host that
/// skips this hears every melodic part as Acoustic Grand Piano, because that is
/// what a General MIDI channel defaults to. Percussion is the exception and
/// masks the bug: channel 9 selects the drum bank whatever the program says.
///
/// Android: `nativeInstrumentParams`, which returns the same fields as an
/// `InstrumentParamsCodec` payload.
@JS public struct MixerStrip {
    public var partIndex: Int
    /// Index into the part's DEDUPED instruments, in first-appearance order.
    public var ordinal: Int
    /// The live MIDI channel (`0...15`) this strip sounds on — the channel
    /// `renderMidi`'s sequence actually uses, not the part's tick-0 channel.
    public var channel: Int
    /// Bank LSB. `0` for everything General MIDI, which is every score this
    /// package has seen; carried so a host can send CC 32 when it is not.
    public var bank: Int
    /// GM patch number, `0...127`.
    public var program: Int
    /// Percussion. Its program is meaningless — channel 9 picks the drum bank —
    /// and a host should not offer a patch picker for it.
    public var isDrums: Bool
    /// The score's own channel volume (MIDI CC 7, `0...127`); the strip's
    /// initial level, and the balance the composer wrote.
    public var volume: Int
    /// Mixer label — the bare part name for a primary strip,
    /// "Part (Instrument)" for a secondary one whose instrument differs.
    public var displayName: String

    /// Spelled out rather than left to the memberwise default, which would be
    /// `internal`: BridgeJS generates a `@_transparent` lowering function that
    /// cannot reference an internal declaration.
    public init(
        partIndex: Int,
        ordinal: Int,
        channel: Int,
        bank: Int,
        program: Int,
        isDrums: Bool,
        volume: Int,
        displayName: String,
    ) {
        self.partIndex = partIndex
        self.ordinal = ordinal
        self.channel = channel
        self.bank = bank
        self.program = program
        self.isDrums = isDrums
        self.volume = volume
        self.displayName = displayName
    }
}

/// The 128 General MIDI patch names, in program order — index 0 is program 0.
///
/// Single-sourced from `SheetMusicAudioCore.GMInstrument` for the same reason
/// Android loads it over JNI (`nativeGMInstrumentList`) rather than keeping a
/// Kotlin copy: a second transcription of 128 names is a second thing to get
/// wrong, and nothing would notice for a long time.
///
/// Takes no handle — it is a constant table, not a property of a score. Call it
/// once and cache it; the strings cross the bridge each time.
@JS public func gmInstrumentNames() -> [String] {
    GMInstrument.all.map(\.name)
}

/// The GM family each program belongs to, parallel to `gmInstrumentNames()` —
/// index 0 is program 0's family. Sixteen distinct strings, repeated; for
/// grouping a patch picker into "Piano", "Bass", "Synth Lead" and so on.
@JS public func gmInstrumentFamilies() -> [String] {
    GMInstrument.all.map(\.family.rawValue)
}

/// How many mixer strips `handle` has. `0` for an unknown handle.
///
/// Paired with `mixerStrip(handle:index:)` rather than returning the whole
/// array: BridgeJS's support for an array of `@JS struct` is not something this
/// package has established, and the call happens once per score load, so the
/// loop costs nothing worth the risk.
@JS public func mixerStripCount(handle: Int) -> Int {
    guard let score = scoreTable.value(for: Int64(handle)) else { return 0 }
    return LiveChannelPlan.build(score: score).strips.count
}

/// The strip at `index`, or `nil` when the handle is unknown or the index is
/// out of range.
@JS public func mixerStrip(handle: Int, index: Int) -> MixerStrip? {
    guard let score = scoreTable.value(for: Int64(handle)) else { return nil }
    let plan = LiveChannelPlan.build(score: score)
    guard index >= 0, index < plan.strips.count else { return nil }
    let strip = plan.strips[index]
    return MixerStrip(
        partIndex: strip.partIndex,
        ordinal: strip.ordinal,
        channel: strip.liveChannel,
        bank: Int(strip.instrument.channel.bank),
        program: Int(strip.instrument.channel.program),
        isDrums: strip.instrument.useDrumset,
        volume: Int(strip.instrument.channel.volume),
        // The same rule the Apple engine fills `MixerChannel` with, shared
        // rather than restated — the two used to be separate copies under a
        // comment promising they matched.
        displayName: plan.labels(for: strip, in: score).displayName,
    )
}
