/// How a chord or rest joins the beam around it — MuseScore's per-ChordRest `BeamMode` (`types/types.h`), the setting
/// its beam palette edits and its MusicXML import writes from `<beam>`. `auto` leaves it to the meter's grouping;
/// every other case wins over that grouping, as `Groups::baseBeamMode` lets an explicit mode win.
///
/// The raw values are the tokens `<BeamMode>` carries in a file (`TConv`, `types/typesconv.cpp:2363-2369`).
public enum BeamMode: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Grouped by the meter's rule.
    case auto
    /// Not beamed: the chord keeps its flag and ends the beam it would have joined (`no`).
    case none = "no"
    /// Starts a new beam here, closing the one before.
    case begin
    /// Continues the beam it follows, even across a beat or the half bar the meter would break at.
    case mid
    /// Closes the beam after this chord.
    case end
    /// Continues the beam but breaks the beams below the first (MuseScore draws one bar across, the rest restart).
    /// Grouped as `mid`: the layout draws a group's secondary bars without that break.
    case begin16
    /// Continues the beam but breaks the beams below the second. Grouped as `mid`, as `begin16` is.
    case begin32

    /// Whether the chord continues the beam it follows rather than starting one (`beamModeMid` plus `end`).
    var continuesBeam: Bool {
        switch self {
        case .mid, .end, .begin16, .begin32: true
        case .auto, .none, .begin: false
        }
    }
}
