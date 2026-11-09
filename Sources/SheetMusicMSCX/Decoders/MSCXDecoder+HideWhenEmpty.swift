import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// How a file says which staves hide when they are empty — `<Part><Staff><hideWhenEmpty>`, and since 4.60
/// `<Part><hideWhenEmpty>` and `<Part><hideStavesWhenIndividuallyEmpty>` — read into `Staff.hideWhenEmpty`,
/// `Part.hideWhenEmpty` and `Part.hideStavesWhenIndividuallyEmpty`.
///
/// MuseScore changed the model at 4.60. Since then the part and each staff carry an `AutoOnOff` written as
/// `auto` / `on` / `off` (`rw/read460/tread.cpp:3611-3614`, `4068-4069`). Before, only a staff carried a mode, as an
/// integer — 0 AUTO, 1 ALWAYS, 2 NEVER, 3 INSTRUMENT (`rw/compat/compattypes.h:32-37`) — which MuseScore 4.6 converts
/// into the new model a part at a time when it reads one (`TRead::read(Part*, StaffHideModes&, bool)`,
/// `rw/read400/tread.cpp:3315-3387`, used by the 3.x, 4.0 and 4.1–4.5 readers alike). Most files in the wild carry the
/// integer form, so the conversion is reproduced here exactly, inputs and quirks included.
enum HideWhenEmptyDecoding {
    /// The first file format whose `<hideWhenEmpty>` is the string form (`rw/rwregister.cpp:52-56`: below 460 a file
    /// goes to a reader that reads the integer).
    static let stringFormRevision = 460

    /// Whether a file of `formatRevision` writes the integer form. A file without a readable version is taken to be
    /// current, as every other version-dependent read here takes it.
    static func isLegacy(formatRevision: Int?) -> Bool {
        (formatRevision ?? stringFormRevision) < stringFormRevision
    }

    /// A 4.60 value as `TConv::fromXml(…, AutoOnOff::AUTO)` reads it (`types/typesconv.cpp:1008-1022`): an exact
    /// `auto` / `on` / `off`, anything else `auto`.
    static func autoOnOff(_ text: String) -> AutoOnOff {
        AutoOnOff(rawValue: text) ?? .auto
    }

    /// A pre-4.60 staff's mode as `static_cast<StaffHideMode>(e.readInt())` reads it
    /// (`rw/read400/tread.cpp:3818-3819`): the integer, with a value that is not one read as 0 and an absent tag as 0
    /// (`staffHideModes[staff]` inserts AUTO). Kept as the raw integer, since a value outside 0...3 matches none of the
    /// conversion's cases and that matters to it.
    static func legacyMode(_ text: String?) -> Int {
        text.flatMap { Int($0) } ?? 0
    }

    /// What the pre-4.60 staff modes of one part, in staff order, become — `rw/read400/tread.cpp:3315-3387` line for
    /// line. `globalHideEmptyStaves` is the score's `<hideEmptyStaves>` style, which the conversion consults.
    static func resolveLegacy(
        staffModes: [Int], globalHideEmptyStaves: Bool,
    ) -> (part: AutoOnOff, individually: Bool, staves: [AutoOnOff]) {
        let auto = 0, always = 1, never = 2, instrument = 3
        var part = AutoOnOff.auto
        var individually = false
        var staves = Array(repeating: AutoOnOff.auto, count: staffModes.count)
        guard !staffModes.isEmpty else { return (part, individually, staves) }
        if staffModes.count == 1 {
            switch staffModes[0] {
            case always: part = .on
            case never: part = .off
            default: break
            }
            return (part, individually, staves)
        }
        if staffModes.allSatisfy({ $0 == always }) {
            return (.on, true, staves)
        }
        if staffModes.allSatisfy({ $0 == never }) {
            return (.off, false, staves)
        }
        if globalHideEmptyStaves, staffModes.contains(auto), !staffModes.contains(instrument) {
            individually = true
        }
        for (index, mode) in staffModes.enumerated() {
            switch mode {
            case always: staves[index] = .on
            case never: staves[index] = .off
            default: break
            }
        }
        return (part, individually, staves)
    }

    /// The pre-4.60 integer each staff of `part` is written with in the 3.02 output — the inverse of `resolveLegacy`
    /// wherever one exists. `nil` is AUTO (0), left unwritten as MuseScore 3 leaves it. `globalHideEmptyStaves` is the
    /// score's `ScoreStyle.hideEmptyStaves`, which the read-back consults.
    ///
    /// A staff that decides for itself writes 1 (`on`) or 2 (`off`). An `auto` staff takes its part's setting: `off`
    /// is 2, and `on` is 1 when the staves hide one by one (all ALWAYS reads back as `on` with individual hiding) or
    /// the part has one staff. A multi-staff part whose staves hide only together writes INSTRUMENT (3), which reads
    /// back as an `auto` part hiding them together; that is exact for an `auto` part, and for an `on` part it is the
    /// one loss — such a part hides again only while the style is on. An `auto` part with individual hiding writes
    /// AUTO, which reads back with individual hiding whenever the style is on, and when it is off an `auto` part
    /// hides nothing, so INSTRUMENT is written only under the style: without it nothing reads it.
    static func legacyModes(of part: Part, globalHideEmptyStaves: Bool) -> [Int?] {
        let together = part.staves.count > 1 && !part.hideStavesWhenIndividuallyEmpty
        return part.staves.map { staff in
            switch staff.hideWhenEmpty {
            case .on: return 1
            case .off: return 2
            case .auto: break
            }
            switch part.hideWhenEmpty {
            case .off: return 2
            case .on: return together ? 3 : 1
            case .auto: return together && globalHideEmptyStaves ? 3 : nil
            }
        }
    }
}
