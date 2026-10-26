import SheetMusicCore
import SheetMusicXMLTools

/// What a note says about its stem: the direction its `<stem>` sets (`MusicXmlParserPass2::stem`: `up` or `down`;
/// `none` and `double` set none) and where its first `<beam>` puts it (`computeBeamMode`).
struct MusicXMLStemBeam: Equatable {
    enum BeamMode: Equatable {
        /// `begin` on beam 1: the note opens a beam, which takes the note's `<stem>` as its direction.
        case begin
        /// `continue` on beam 1 — MuseScore's `MID`, and its `BEGIN16` / `BEGIN32`, which only restart inner beams.
        case continuing
        /// `end` on beam 1.
        case end
        /// No beam 1, or a hook on it: MuseScore's `AUTO`, which takes the note out of any open beam.
        case none
    }

    let direction: StemDirectionOverride?
    let beamMode: BeamMode

    init(node: XMLTreeNode) {
        direction = node.first("stem").flatMap { StemDirectionOverride(mscxValue: $0.text) }
        let first = node.all("beam").first { ($0.attributes["number"] ?? "1") == "1" }?.text
        beamMode = switch first {
        case "begin": .begin
        case "continue": .continuing
        case "end": .end
        default: .none
        }
    }
}
