import SheetMusicFoundation

/// Writes a volta bracket over the MEASURES `range` touches.
///
/// A volta is a measure-level marking, so — like the layout breaks, markers, jumps and repeat flags of §3.1 — it
/// is written on `Score.canonicalStaff` only, whatever staff the range names: at index 0 of voice 0 of the first
/// measure, ahead of that bar's own clef / key / time (MuseScore writes it there too,
/// `testVoltaDynamic.mscx:217-220`), ending at the END of the last measure. Signatures cost no ticks, so the
/// volta's position within the bar is 0 either way.
///
/// `endings` are the take numbers (`1`, `2`, …); an empty list is a bracket with no number, which MuseScore also
/// writes. `text` becomes `beginText`, trimmed; empty after trimming is `nil`, meaning "use the styled label for
/// this volta", not a refusal — a volta with no label is a legal volta.
///
/// > Important: This command and `RemoveSpanner` are not symmetric about the staff. `SetVolta` re-homes any
/// > range to the canonical staff, but `RemoveSpanner` is staff-literal: it takes the element at exactly the
/// > `VoiceElementID` given. So `SetVolta(over: aCelloRange)` writes on the flute and
/// > `RemoveSpanner(at: aCelloSlot, kind: .volta)` refuses — a caller undoing a volta must address the
/// > canonical staff itself (this command's `affectedLocation` is exactly that address).
///
/// > Note: This command is sugar over `ReplaceVoiceElements`. See `docs/edit-commands.md`.
public struct SetVolta: EditCommand {
    public let range: VoiceElementRange
    public let endings: [Int]
    public let text: String?

    public init(over range: VoiceElementRange, endings: [Int], text: String?) {
        self.range = range
        self.endings = endings
        self.text = text
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: Score.canonicalStaff,
            measureIndex: min(range.start.measureIndex, range.end.measureIndex),
            voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let label = text?.trimmingWhitespaceAndNewlines()
        let template = Spanner(
            kind: .volta, rawType: Spanner.Kind.volta.rawValue, voltaEndings: endings,
            beginText: (label?.isEmpty ?? true) ? nil : label,
        )
        return try SpannerPlacement.add(
            template, over: range, in: score, operation: String(describing: Self.self),
        ).apply(to: &score)
    }
}
