/// Properties shared by all engravable elements — the subset of
/// MuseScore's base `EngravingItem` persisted state this library models.
/// Deliberately a struct (not an OptionSet): the upstream base set is
/// mostly non-visual (offset, autoplace, placement, part-linking, …) and
/// keeps growing, so value-typed fields must be addable here later.
/// C++: mu::engraving::EngravingItem base properties (subset).
public struct ElementProperties: Sendable, Equatable, Codable {
    /// Hidden from rendered/printed output. MuseScore
    /// `ElementFlag::INVISIBLE` / `<visible>0</visible>`. Default true.
    /// Playback (MIDI) is unaffected — sounding is governed elsewhere
    /// (e.g. `Note.play`).
    public var visible: Bool

    /// Author-supplied element color (RGBA 0..255). MuseScore
    /// `<color r="…" g="…" b="…" a="…"/>`. `nil` = inherit the default
    /// (black / voice color). Applies to the element's own ink —
    /// noteheads, rests, lyrics, etc. — wherever a renderer honors it.
    public var color: ScoreColor?

    /// Author-supplied engraving offset in spatium units. `nil` means the
    /// MSCX `<offset>` child was absent; an explicit zero tag decoded from a
    /// file is represented by `ScoreOffset(x: 0, y: 0)`. Swift construction
    /// through an element's zero-valued `offsetX` / `offsetY` initializer
    /// parameters is indistinguishable from no offset and stores `nil`.
    public var offset: ScoreOffset?

    /// Author override for which side of the staff the element sits on.
    /// `nil` means the MSCX `<placement>` child was absent, so the element uses
    /// its styled or algorithmic side. MuseScore writes this tag only after
    /// the property stops being styled (`TWrite::writeItemProperties`,
    /// `twrite.cpp:578`).
    public var placement: Placement?

    // Reserved extension points (NOT implemented in this work):
    //   public var autoplace   // behavioral

    public init(
        visible: Bool = true,
        color: ScoreColor? = nil,
        offset: ScoreOffset? = nil,
        placement: Placement? = nil,
    ) {
        self.visible = visible
        self.color = color
        self.offset = offset
        self.placement = placement
    }

    public static let `default` = ElementProperties()
}
