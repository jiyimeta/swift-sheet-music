/// The source of an engraved barline within a measure.
public enum BarLineRole: Hashable, Sendable {
    /// An explicit `VoiceElement.barLine`.
    case explicit
    /// A barline synthesized from `Measure.startRepeat`.
    case startRepeat
    /// A synthesized end-of-bar when no explicit barline exists.
    case trailing
}
