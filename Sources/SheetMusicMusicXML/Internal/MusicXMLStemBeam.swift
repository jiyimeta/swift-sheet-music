import SheetMusicCore
import SheetMusicXMLTools

/// What a note says about its stem and its beam: the direction its `<stem>` sets (`MusicXmlParserPass2::stem`: `up` or
/// `down`; `none` and `double` set none), the mode its `<beam>`s make (`computeBeamMode`), and the mode its chord takes
/// when no beam holds it.
struct MusicXMLStemBeam: Equatable {
    let direction: StemDirectionOverride?
    /// MuseScore's `computeBeamMode` (`importmusicxmlpass2.cpp:6635-6656`) over the note's `<beam>`s, the first of each
    /// level kept as `MusicXmlParserPass2::beam` keeps it (`:8032-8039`, a `<beam>` with no `number` being level 1):
    /// `continue` on level 1 with `begin` on level 2 is `begin16`, with `continue` on 2 and `begin` on 3 `begin32`;
    /// otherwise level 1's `begin`, `continue` or `end` is `begin`, `mid` or `end`, and anything else — a hook, or no
    /// beam — `auto`.
    let beamMode: BeamMode
    /// The mode the chord takes when no beam holds it (`handleBeamAndStemDir`, `importmusicxmlpass2.cpp:2522-2534`):
    /// `no` when the score carries beaming information and the note can take a beam — an eighth or shorter — else
    /// `auto`.
    let unbeamedMode: BeamMode

    /// `hasBeamingInfo` is the score's (`hasBeamingInfo(root:)`), bound for the decode in `MusicXMLDecodeContext`.
    init(
        node: XMLTreeNode, divisions: DivisionsContext,
        hasBeamingInfo: Bool = MusicXMLDecodeContext.hasBeamingInfo,
    ) {
        direction = node.first("stem").flatMap { StemDirectionOverride(mscxValue: $0.text) }
        var levels: [Int: String] = [:]
        for beam in node.all("beam") {
            let level = beam.attributes["number"].flatMap { Int($0) } ?? 1
            if levels[level] == nil { levels[level] = beam.text }
        }
        beamMode = switch (levels[1], levels[2], levels[3]) {
        case ("continue"?, "begin"?, _): .begin16
        case ("continue"?, "continue"?, "begin"?): .begin32
        case ("begin"?, _, _): .begin
        case ("continue"?, _, _): .mid
        case ("end"?, _, _): .end
        default: .auto
        }
        unbeamedMode = hasBeamingInfo && Self.canGetBeam(node, divisions: divisions) ? .none : .auto
    }

    /// Whether the score carries beaming information (MuseScore's `hasBeamingInfo`): a `<beam>` on any note
    /// (`importmusicxmlpass1.cpp:3410-3412`), or `<supports element="beam" type="yes">` in its encoding (`:1530-1532`).
    static func hasBeamingInfo(root: XMLTreeNode) -> Bool {
        let supports = root.all("identification").flatMap { $0.all("encoding") }.flatMap { $0.all("supports") }
        if supports.contains(where: { $0.attributes["element"] == "beam" && $0.attributes["type"] == "yes" }) {
            return true
        }
        return root.all("part").contains { part in
            part.all("measure").contains { measure in
                measure.all("note").contains { note in note.children.contains { $0.name == "beam" } }
            }
        }
    }

    /// The types MuseScore lets a chord be beamed at: an eighth down to a 1024th (`canGetBeam`,
    /// `importmusicxmlpass2.cpp:2527-2528`).
    private static let beamableTypes: Set = ["eighth", "16th", "32nd", "64th", "128th", "256th", "512th", "1024th"]

    /// MuseScore's `canGetBeam` over the chord's duration type as `determineDuration` sets it
    /// (`importmusicxmlpass2.cpp:6453-6478`): its `<type>`, a type MuseScore does not know reading as a quarter; for a
    /// note with no `<type>`, the type its `<duration>` fits (`TDuration::setVal`, `durationtype.cpp:85-109`) — an
    /// eighth or shorter up to 465 ticks of 480 to the quarter, past which it rounds up to a quarter.
    private static func canGetBeam(_ node: XMLTreeNode, divisions: DivisionsContext) -> Bool {
        if let type = node.first("type")?.text, !type.isEmpty { return beamableTypes.contains(type) }
        guard let text = node.first("duration")?.text, let value = Int(text), value > 0, divisions.perQuarter > 0
        else { return false }
        let length = divisions.fractionOfWhole(value)
        // `Fraction::ticks` rounds to the nearest tick; a length of no tick is a measure's duration type.
        let ticks = (length.numerator * 1920 + length.denominator / 2) / length.denominator
        return ticks >= 1 && ticks <= 465
    }
}
