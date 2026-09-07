import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intent 74 (macOS score-text-entry, spec 2026-09-07 — the catalogue's last). The tag layout is
// documented in `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the rules there apply
// unchanged — every field mandatory, the optional text as a `has` + value pair, the syllabic as a `u8` with a
// throwing table.
//
// The payload is a REPEATED message, the shape `SetJumpsIntentWire` and `SetMarkersIntentWire` (intents 48 and 49)
// already use — `@WireFormat` encodes an array of messages as a repeated field. What differs is why: those carry a
// list because a bar's jumps or markers ARE a list, whereas one lyric keystroke is a single gesture that lands in
// up to three places, and the three must cross as one unit because they are one undo step on the far side.

/// The `LyricSyllableWriteWire` table, in a type of its own so the payload struct carries stored INSTANCE
/// properties only — `@WireFormat` numbers those into tags (the `BreathTables` / `HarmonyTables` precedent).
private enum LyricTables {
    /// Index = wire value. Hand-written: `Syllabic`'s case order is Core's, not this codec's, and `Syllabic` carries
    /// no `rawValue` to borrow.
    static let syllabics: [Syllabic] = [.single, .begin, .middle, .end]
}

@WireFormat
public struct LyricSyllableWriteWire {
    public var location: VoiceElementIDWire
    public var verse: Int32
    public var hasText: UInt8
    public var text: String
    /// 0 single / 1 begin / 2 middle / 3 end; 0 when `hasText == 0`.
    public var syllabic: UInt8
    /// Melisma length in ticks; 0 when `hasText == 0`.
    public var ticks: Int32

    public init(from write: LyricSyllableWrite) {
        location = VoiceElementIDWire(from: write.location)
        verse = Int32(write.verse)
        hasText = write.text == nil ? 0 : 1
        text = write.text ?? ""
        syllabic = write.text == nil
            ? 0
            : LyricTables.syllabics.firstIndex(of: write.syllabic).map { UInt8($0) } ?? 0
        ticks = write.text == nil ? 0 : Int32(write.ticks)
    }

    /// Throws `unknownChoiceDiscriminator` for a syllabic outside the table. A removal decodes as `.single` with no
    /// melisma, which is what `SetLyric` ignores anyway when the text is `nil`.
    public func decoded() throws -> LyricSyllableWrite {
        guard hasText != 0 else {
            return LyricSyllableWrite(location: location.decoded(), verse: Int(verse), text: nil)
        }
        guard LyricTables.syllabics.indices.contains(Int(syllabic)) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(syllabic))
        }
        return LyricSyllableWrite(
            location: location.decoded(),
            verse: Int(verse),
            text: text,
            syllabic: LyricTables.syllabics[Int(syllabic)],
            ticks: Int(ticks),
        )
    }
}

@WireFormat
public struct SetLyricSyllablesIntentWire {
    public var writes: [LyricSyllableWriteWire]

    public init(writes: [LyricSyllableWrite]) {
        self.writes = writes.map(LyricSyllableWriteWire.init(from:))
    }

    public func decoded() throws -> [LyricSyllableWrite] {
        try writes.map { try $0.decoded() }
    }
}
