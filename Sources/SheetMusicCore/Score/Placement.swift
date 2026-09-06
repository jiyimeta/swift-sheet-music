/// Which side of the staff an element sits on.
/// C++: `mu::engraving::PlacementV`; MSCX tokens "above" / "below"
/// (`types/typesconv.cpp:2257-2259`).
///
/// This is deliberately closed because upstream `PlacementV` is closed. The
/// MSCX decoder diagnoses and drops an unrecognized token rather than keeping
/// it in preserved markup. If MuseScore adds a third value, extend this type
/// so the shared element-property decoder can retain it.
public enum Placement: String, Sendable, Equatable, Codable {
    case above
    case below
}
