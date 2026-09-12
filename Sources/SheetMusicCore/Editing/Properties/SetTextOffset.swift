import SheetMusicFoundation

/// Writes one engraved text's authored offset in spatium units; nil restores its styled position.
///
/// Addressed by `ScoreTextID` — lyric, staff and system text, harmony, rehearsal mark — because those four are
/// exactly the carriers whose offset reaches the page. The layout reads `ElementProperties.offset` in one place,
/// `LayoutEngine.placedTextOrigin`, whose callers cover exactly those four kinds — five call sites, not four: the
/// fifth (`LayoutDocument+EmptyTextEntryOrigin.swift`) places the text-entry cursor from that same authored offset,
/// one more reader of the same four kinds rather than a fifth kind. A note, a chord, a dynamic or a spanner stores
/// an offset and round-trips it without moving, which is why this command does not accept them: an inspector row
/// over an inert write is worse than no row.
///
/// The offset is applied on top of the resolved side, so it composes with `SetElementPlacement` rather than
/// replacing it.
///
/// > Note: This command is sugar over the lane and chord writes `TextElementProperties` owns. It exists to give
/// > the operation a domain-meaningful name and to centralise the small bit of validation it performs. See
/// > `docs/edit-commands.md` for the policy.
public struct SetTextOffset: EditCommand {
    public let text: ScoreTextID
    public let offset: ScoreOffset?

    public init(_ text: ScoreTextID, offset: ScoreOffset?) {
        self.text = text
        self.offset = offset
    }

    public var affectedLocation: VoiceElementID {
        TextElementProperties.anchor(of: text)
    }

    /// Nil means the target is absent; a present carrier with an inherited offset still returns properties.
    /// The planner must distinguish these so clearing a missing target is refused instead of skipped.
    public static func currentProperties(for text: ScoreTextID, in score: Score) -> ElementProperties? {
        TextElementProperties.current(text, in: score)
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let old = Self.currentProperties(for: text, in: score) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        guard TextElementProperties.update(text, in: &score, { $0.offset = offset }) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        return SetTextOffset(text, offset: old.offset)
    }
}
