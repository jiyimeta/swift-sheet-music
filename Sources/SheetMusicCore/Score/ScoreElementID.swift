/// A selectable engraved element, addressed exactly as its editing command addresses it.
public enum ScoreElementID: Hashable, Sendable {
    /// The chord with notes that `SetDynamic` addresses, deliberately not the dynamic's own slot.
    /// Same-kind markings in one attachment run are indistinguishable to selection, as to the command.
    /// A durable name for the marking's own slot would name a different element than this neighbor address;
    /// resolving that seam belongs to the stable-identifier work's per-case table, as it does for harmony.
    case dynamic(anchor: VoiceElementID)
    /// The chord or rest that `SetFermata` addresses, deliberately not the fermata's own slot.
    /// Same-kind markings in one attachment run are indistinguishable to selection, as to the command.
    /// A durable name for the marking's own slot would name a different element than this neighbor address;
    /// resolving that seam belongs to the stable-identifier work's per-case table, as it does for harmony.
    case fermata(anchor: VoiceElementID)
    /// The preceding chord with notes that `SetBreath(after:)` addresses, not the breath's own slot.
    /// Same-kind markings in one attachment run are indistinguishable to selection, as to the command.
    /// A durable name for the marking's own slot would name a different element than this neighbor address;
    /// resolving that seam belongs to the stable-identifier work's per-case table, as it does for harmony.
    case breath(anchor: VoiceElementID)
    /// The chord or rest that `SetTempo` addresses, deliberately not the tempo mark's own slot.
    /// The mark lives in `SystemMeasure.elements`, a different collection from the anchor's, so this
    /// anchor cannot one day be replaced by a name for the tempo itself — there is no slot in
    /// `Voice.elements` for it to become. Same neighbor-address seam as the markings above and as
    /// harmony: a durable name for the mark would identify a different element than this address,
    /// and resolving that belongs to the stable-identifier work's per-case table.
    case tempo(anchor: VoiceElementID)
    /// Transitional positional address of a spanner's `Voice.elements` slot, qualified by kind.
    /// A volta names its current slot, just as other voice-element spanners do.
    /// `SetVolta` re-homes a range to the canonical staff on insertion; `RemoveSpanner` addresses
    /// the slot the volta actually occupies, including a noncanonical staff or a shifted element index.
    /// The slot's durable identifier is available through `Score.eid(at:)`.
    case spanner(anchor: VoiceElementID, kind: Spanner.Kind)
    /// Transitional positional bar address for a key signature stored in `Voice.elements`, on the staff whose
    /// glyph was selected.
    /// `SetKeySignature` writes the leading signature run of voice zero on every pitched staff, and takes only
    /// `measureIndex`. `staff` is the SELECTION's: one bar draws a key signature on every staff, and a click on
    /// one of them selects that one glyph (as in MuseScore) rather than lighting up the whole column. Two
    /// identities differing only in `staff` therefore address the same command.
    /// Mid-bar keys, keys outside that run or voice, and unpitched-staff keys have no identity by design.
    /// **The bar named is the one the glyph is DRAWN in**, which for a system-head restatement is the bar
    /// opening that system rather than the bar that declared the key: `SetKeySignature(measureIndex:)` on a bar
    /// that declares none adds a declaration there (`KeySig::drop`'s rule in MuseScore), so an edit through a
    /// restatement changes the key from that system on and leaves the earlier ones alone, and
    /// `RemoveKeySignature` on it plans to nothing. The one glyph that names another bar is an end-of-system
    /// courtesy announcement, which names the bar it announces.
    /// Each staff's declaration slot has its own durable identifier, available through `Score.eid(at:)`.
    case keySignature(measureIndex: Int, staff: StaffAddress)
    /// Transitional positional bar address for a time signature stored in `Voice.elements`, on the staff whose
    /// glyph was selected.
    /// Names the bar's meter for `SetTimeSignature`, not an individual declaration's voice slot; `staff` is the
    /// selection's, exactly as for `keySignature`, and the command does not read it.
    /// The command reads declarations anywhere in a bar and replaces existing meters in re-barred runs;
    /// it is not restricted to editing a leading signature prefix.
    /// `SetTimeSignature` re-bars the whole span governed by the meter: editing this glyph has wider
    /// consequences than its appearance suggests.
    /// Each declaration slot's durable identifier is available through `Score.eid(at:)`.
    case timeSignature(measureIndex: Int, staff: StaffAddress)
    /// Transitional positional bar address, with a role distinguishing explicit and synthesized barlines.
    /// An explicit barline occupies a `Voice.elements` slot; synthesized roles have no slot to name.
    /// Only the last explicit barline after voice zero's last chord or rest is reached by `SetBarLine`.
    /// Other explicit glyphs have no identity by design. The role names the source, not a unique command:
    /// `BarLineRole` records which command owns each editable aspect, including synthesized repeat flags.
    /// An explicit barline's slot has a durable identifier, available through `Score.eid(at:)`.
    case barLine(measureIndex: Int, role: BarLineRole)
    /// Permanent positional address through the owning chord and the articulation's kind.
    /// This property keeps its owner-based address rather than acquiring its own EID.
    /// Duplicate articulations of the same kind are indistinguishable, as they are to `SetArticulation`.
    case articulation(anchor: VoiceElementID, kind: ChordArticulation.Kind)

    /// A tie owned by its two endpoint notes.
    case tie(start: NoteID, end: NoteID)
    /// A chord-attached or standalone slur; see `SlurID`.
    case slur(SlurID)
    /// One entry in the owning staff's measure-level jumps list.
    case jump(staff: StaffAddress, measureIndex: Int, index: Int)
    /// One entry in the owning staff's measure-level markers list.
    case marker(staff: StaffAddress, measureIndex: Int, index: Int)

    /// The voice-element owner anchor, or `nil` for bar and staff-owned navigation lists.
    public var anchor: VoiceElementID? {
        switch self {
        case let .dynamic(anchor), let .fermata(anchor), let .breath(anchor), let .tempo(anchor),
             let .spanner(anchor, _), let .articulation(anchor, _): return anchor
        case let .tie(start, _): return VoiceElementID(start)
        case let .slur(id): return id.anchor
        case .keySignature, .timeSignature, .barLine, .jump, .marker: return nil
        }
    }

    /// The bar a bar-addressed command takes, or `nil` for anchored and staff-owned navigation identities.
    public var measureIndexIfAddressedByBar: Int? {
        switch self {
        case let .keySignature(index, _), let .timeSignature(index, _), let .barLine(index, _): return index
        case .dynamic, .fermata, .breath, .tempo, .spanner, .articulation, .tie, .slur, .jump, .marker: return nil
        }
    }

    /// The staff this identity names outright: a signature's selected glyph, or a navigation list's owner.
    /// `nil` for anchored identities (their staff is the anchor's) and for a barline, which names no staff.
    public var staffIfAddressed: StaffAddress? {
        switch self {
        case let .keySignature(_, staff), let .timeSignature(_, staff),
             let .jump(staff, _, _), let .marker(staff, _, _): return staff
        case .dynamic, .fermata, .breath, .tempo, .spanner, .barLine, .articulation, .tie, .slur: return nil
        }
    }
}
