/// The source of an engraved barline within a measure.
public enum BarLineRole: Hashable, Sendable {
    /// An explicit `VoiceElement.barLine` whose style `SetBarLine` can replace or remove:
    /// the last barline after voice zero's last chord or rest. Other explicit glyphs have no identity.
    /// Repeat-looking explicit styles remain voice elements; `SetRepeatBarLines` edits measure flags,
    /// not this slot's style.
    case explicit
    /// A barline synthesized from `Measure.startRepeat`, edited by `SetRepeatBarLines`.
    /// `SetBarLine` edits the end barline and cannot change this start-repeat flag.
    case startRepeat
    /// A synthesized end-of-bar when no explicit barline supplies it.
    /// `SetBarLine` supplies an explicit end style, or removes that override for `.normal`.
    /// When the synthesized glyph is an end-repeat, `SetRepeatBarLines` owns its repeat count/flag;
    /// setting a style does not clear that flag. The role names the glyph source, not a single edit command.
    case trailing
}
