import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload struct for intent 73 (edit-command parity, group 7 — the catalogue's last). The tag layout is documented
// in `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the rules there apply unchanged —
// every field mandatory, the optional name as a `has` + value pair, the harmony type as a `u8` with a throwing
// table.

/// The `SetChordSymbolIntentWire` table, in a type of its own so the payload struct carries stored INSTANCE
/// properties only — `@WireFormat` numbers those into tags (the `BreathTables` precedent).
private enum HarmonyTables {
    /// Index = wire value. Hand-written: `HarmonyType`'s case order is Core's, not this codec's.
    static let types: [HarmonyType] = [.standard, .roman, .nashville]
}

@WireFormat
public struct SetChordSymbolIntentWire {
    public var location: VoiceElementIDWire
    public var hasName: UInt8
    public var name: String
    /// 0 standard / 1 roman / 2 nashville; 0 when `hasName == 0`.
    public var harmonyType: UInt8

    public init(location: VoiceElementID, name: String?, harmonyType: HarmonyType) {
        self.location = VoiceElementIDWire(from: location)
        hasName = name == nil ? 0 : 1
        self.name = name ?? ""
        self.harmonyType = name == nil
            ? 0
            : HarmonyTables.types.firstIndex(of: harmonyType).map { UInt8($0) } ?? 0
    }

    /// Throws `unknownChoiceDiscriminator` for a type outside the table. A removal decodes as `.standard`.
    public func decoded() throws -> (location: VoiceElementID, name: String?, harmonyType: HarmonyType) {
        guard hasName != 0 else { return (location: location.decoded(), name: nil, harmonyType: .standard) }
        guard HarmonyTables.types.indices.contains(Int(harmonyType)) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(harmonyType))
        }
        return (location: location.decoded(), name: name, harmonyType: HarmonyTables.types[Int(harmonyType)])
    }
}
