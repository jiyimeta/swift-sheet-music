import SheetMusicFoundation

/// Writes one engraved text's collision-avoidance override; nil inherits the default, which is true.
///
/// Addressed by `ScoreTextID` for the same reason as `SetTextOffset`: `ElementProperties.autoplace` is honored
/// by the layout for lyric, staff and system text, rehearsal mark and harmony, and for nothing else — its own doc
/// comment says so, and `LayoutEngine+Placement` reads it into `TextPlacementMetadata` for those kinds only.
///
/// False pins the element where its side and offset put it, and the skyline then treats it as a fixed obstacle
/// other elements avoid, rather than moving it out of their way.
///
/// > Note: This command is sugar over the lane and chord writes `TextElementProperties` owns. It exists to give
/// > the operation a domain-meaningful name and to centralise the small bit of validation it performs. See
/// > `docs/edit-commands.md` for the policy.
public struct SetTextAutoplace: EditCommand {
    public let text: ScoreTextID
    public let autoplace: Bool?

    public init(_ text: ScoreTextID, autoplace: Bool?) {
        self.text = text
        self.autoplace = autoplace
    }

    public var affectedLocation: VoiceElementID {
        TextElementProperties.anchor(of: text)
    }

    /// Nil means the target is absent; a present carrier inheriting the default still returns properties.
    public static func currentProperties(for text: ScoreTextID, in score: Score) -> ElementProperties? {
        TextElementProperties.current(text, in: score)
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let old = Self.currentProperties(for: text, in: score) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        guard TextElementProperties.update(text, in: &score, { $0.autoplace = autoplace }) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        return SetTextAutoplace(text, autoplace: old.autoplace)
    }
}
