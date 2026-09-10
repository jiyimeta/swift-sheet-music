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
    /// P2b supplies its durable EID through `Score.eid(at:)`.
    case spanner(anchor: VoiceElementID, kind: Spanner.Kind)
    /// Transitional positional bar address for a key signature stored in `Voice.elements`.
    /// `SetKeySignature` writes the leading signature run of voice zero on every pitched staff.
    /// The identity deliberately omits staff and voice, which the command does not take.
    /// Mid-bar keys, keys outside that run or voice, and unpitched-staff keys have no identity by design.
    /// Courtesy announcements and system-head restatements likewise do not name a new declaration.
    /// P2b's successor for the underlying slot's durable name is `Score.eid(at:)`.
    case keySignature(measureIndex: Int)
    /// Transitional positional bar address for a time signature stored in `Voice.elements`.
    /// Names the bar's meter for `SetTimeSignature`, not an individual declaration's voice slot.
    /// The command reads declarations anywhere in a bar and replaces existing meters in re-barred runs;
    /// it is not restricted to editing a leading signature prefix.
    /// `SetTimeSignature` re-bars the whole span governed by the meter: editing this glyph has wider
    /// consequences than its appearance suggests. P2b's durable-name successor is `Score.eid(at:)`.
    case timeSignature(measureIndex: Int)
    /// Transitional positional bar address, with a role distinguishing explicit and synthesized barlines.
    /// An explicit barline occupies a `Voice.elements` slot; synthesized roles have no slot to name.
    /// Only the last explicit barline after voice zero's last chord or rest is reached by `SetBarLine`.
    /// Other explicit glyphs have no identity by design. The role names the source, not a unique command:
    /// `BarLineRole` records which command owns each editable aspect, including synthesized repeat flags.
    /// P2b's successor for a slot's durable name is `Score.eid(at:)`.
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

    /// A staff-independent bar address, or `nil` for anchored and staff-owned navigation identities.
    public var measureIndexIfAddressedByBar: Int? {
        switch self {
        case let .keySignature(index), let .timeSignature(index), let .barLine(index, _): return index
        case .dynamic, .fermata, .breath, .tempo, .spanner, .articulation, .tie, .slur, .jump, .marker: return nil
        }
    }
}
