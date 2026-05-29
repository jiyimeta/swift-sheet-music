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

    // Reserved extension points (NOT implemented in this work):
    //   public var offset: ...             // <offset>
    //   public var autoplace / placement   // behavioral

    public init(visible: Bool = true, color: ScoreColor? = nil) {
        self.visible = visible
        self.color = color
    }

    public static let `default` = ElementProperties()
}
