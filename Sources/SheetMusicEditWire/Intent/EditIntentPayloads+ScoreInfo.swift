import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intent 80 (score credits — title / subtitle / composer / arranger / lyricist / copyright).
// The tag layout is documented in `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the
// rules there apply unchanged — every field mandatory, the optional text as a `has` + value pair, the field name as
// a `u8` with a throwing table.
//
// REPEATED for `SetLyricSyllablesIntentWire`'s reason rather than `SetJumpsIntentWire`'s: a credits form saves
// every field at once and the whole save is one undo step on the far side, so the writes have to cross as one unit.

/// The wire code of each `ScoreInfoWrite.Field`: 0 title / 1 subtitle / 2 composer / 3 arranger / 4 lyricist /
/// 5 copyright. Shared by `ScoreInfoWriteWire` and the credit-geometry payloads (`CreditTextFrameWire`), so a host
/// names a credit the same way everywhere. A type of its own so the payload structs carry stored INSTANCE
/// properties only — `@WireFormat` numbers those into tags (the `LyricTables` / `BreathTables` precedent).
public enum ScoreInfoFieldCode {
    /// Index = wire value. Hand-written rather than taken from `Field.allCases`: a `CaseIterable` order is a
    /// source-file detail and this one is a committed wire layout. Append only; never reorder.
    private static let fields: [ScoreInfoWrite.Field] = [
        .title, .subtitle, .composer, .arranger, .lyricist, .copyright,
    ]

    /// The code of `field`.
    public static func code(of field: ScoreInfoWrite.Field) -> Int32 {
        fields.firstIndex(of: field).map { Int32($0) } ?? 0
    }

    /// The field `code` names; nil for a code outside the table (a newer peer's, or garbage).
    public static func field(code: Int32) -> ScoreInfoWrite.Field? {
        guard code >= 0, Int(code) < fields.count else { return nil }
        return fields[Int(code)]
    }
}

@WireFormat
public struct ScoreInfoWriteWire {
    /// 0 title / 1 subtitle / 2 composer / 3 arranger / 4 lyricist / 5 copyright.
    public var field: UInt8
    public var hasText: UInt8
    /// The credit as typed; "" when `hasText == 0`.
    public var text: String

    public init(from write: ScoreInfoWrite) {
        field = UInt8(ScoreInfoFieldCode.code(of: write.field))
        hasText = write.text == nil ? 0 : 1
        text = write.text ?? ""
    }

    /// Throws `unknownChoiceDiscriminator` for a field outside the table — a payload written by a NEWER peer that
    /// has learned a credit this build has not. Refusing is the rule the rest of the catalogue follows: a credit
    /// silently dropped would look like the user's edit simply not saving.
    public func decoded() throws -> ScoreInfoWrite {
        guard let decodedField = ScoreInfoFieldCode.field(code: Int32(field)) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(field))
        }
        return ScoreInfoWrite(field: decodedField, text: hasText == 0 ? nil : text)
    }
}

@WireFormat
public struct SetScoreInfoIntentWire {
    public var writes: [ScoreInfoWriteWire]

    public init(writes: [ScoreInfoWrite]) {
        self.writes = writes.map(ScoreInfoWriteWire.init(from:))
    }

    public func decoded() throws -> [ScoreInfoWrite] {
        try writes.map { try $0.decoded() }
    }
}
