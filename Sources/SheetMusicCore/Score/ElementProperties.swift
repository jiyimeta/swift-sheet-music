/// Properties shared by all engravable elements — the subset of
/// MuseScore's base `EngravingItem` persisted state this library models.
/// Deliberately a struct (not an OptionSet): the upstream base set is
/// mostly non-visual (offset, autoplace, placement, part-linking, …) and
/// keeps growing, so value-typed fields must be addable here later.
/// C++: mu::engraving::EngravingItem base properties (subset).
public struct ElementProperties: Sendable, Equatable {
    /// Hidden from rendered/printed output. MuseScore
    /// `ElementFlag::INVISIBLE` / `<visible>0</visible>`. Default true.
    /// Playback (MIDI) is unaffected — sounding is governed elsewhere
    /// (e.g. `Note.play`).
    public var visible: Bool

    // Reserved extension points (NOT implemented in this work):
    //   public var color: ScoreColor?      // <color>
    //   public var offset: ...             // <offset>
    //   public var autoplace / placement   // behavioural

    public init(visible: Bool = true) {
        self.visible = visible
    }

    public static let `default` = ElementProperties()
}
