import SheetMusicCore

extension LayoutElement {
    /// Renderable form of a `Spanner`, resolved from its decoded
    /// payload rather than from `Spanner.rawType` — MuseScore writes
    /// one `type=` string per element class (`HairPin`, `Ottava`),
    /// so every variant distinction lives in the payload.
    public enum SpannerKind: Sendable, Equatable {
        case slur
        case volta(endings: [Int])
        /// MuseScore `HairpinType::CRESC_HAIRPIN` — an opening wedge.
        case hairpinOpen
        /// MuseScore `HairpinType::DIM_HAIRPIN` — a closing wedge.
        case hairpinClose
        /// MuseScore `HairpinType::CRESC_LINE` / `DIM_LINE` — the
        /// text-and-dashed-line form ("cresc." / "dim."), not a wedge.
        case hairpinLine(crescendo: Bool)
        case pedal
        /// The subtype drives both the label and above/below placement.
        case ottava(subtype: Spanner.OttavaPayload.Subtype)
        case textLine
        case vibrato(VibratoType)
    }
}
