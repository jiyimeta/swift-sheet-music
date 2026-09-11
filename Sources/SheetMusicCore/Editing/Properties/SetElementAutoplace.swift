import SheetMusicFoundation

/// Writes one engraved text's collision-avoidance override; nil inherits the default, which is true.
///
/// Addressed by `ScoreTextID` for the same reason as `SetElementOffset`: `ElementProperties.autoplace` is honored
/// by the layout for lyric, staff and system text, rehearsal mark and harmony, and for nothing else — its own doc
/// comment says so, and `LayoutEngine+Placement` reads it into `TextPlacementMetadata` for those kinds only.
///
/// False pins the element where its side and offset put it, and the skyline then treats it as a fixed obstacle
/// other elements avoid, rather than moving it out of their way.
///
/// > Note: This command is sugar over the lane and chord writes `TextElementProperties` owns. It exists to give
/// > the operation a domain-meaningful name and to centralise the small bit of validation it performs. See
/// > `docs/edit-commands.md` for the policy.
public struct SetElementAutoplace: EditCommand {
    public let target: ScoreTextID
    public let autoplace: Bool?

    public init(_ target: ScoreTextID, autoplace: Bool?) {
        self.target = target
        self.autoplace = autoplace
    }

    public var affectedLocation: VoiceElementID {
        TextElementProperties.anchor(of: target)
    }

    /// Nil means the target is absent; a present carrier inheriting the default still returns properties.
    public static func currentProperties(for target: ScoreTextID, in score: Score) -> ElementProperties? {
        TextElementProperties.current(target, in: score)
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let old = Self.currentProperties(for: target, in: score) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        guard TextElementProperties.update(target, in: &score, { $0.autoplace = autoplace }) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        return SetElementAutoplace(target, autoplace: old.autoplace)
    }
}
