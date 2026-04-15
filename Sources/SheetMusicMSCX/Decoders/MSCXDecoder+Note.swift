import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Note {
    static func decode(_ node: XMLTreeNode) throws -> Note {
        guard let pitchText = node.first("pitch")?.text, let pitch = Int(pitchText) else {
            throw SheetMusicError.malformedScore(reason: "Note missing <pitch>")
        }
        guard let tpcText = node.first("tpc")?.text, let tpc = Int(tpcText) else {
            throw SheetMusicError.malformedScore(reason: "Note missing <tpc>")
        }
        var accidental: Accidental?
        if let subtype = node.first("Accidental")?.first("subtype")?.text {
            accidental = Accidental(mscxSubtype: subtype)
        }
        // MuseScore 5.x encodes ties inside `<Note>` as
        // `<Spanner type="Tie">` with `<next>` (start) or `<prev>` (end).
        // Numbering is positional in MSCX; default to 1 when present.
        var tieForward: Int?
        var tieBack: Int?
        for spanner in node.all("Spanner") where spanner.attributes["type"] == "Tie" {
            if spanner.children.contains(where: { $0.name == "next" }) { tieForward = 1 }
            if spanner.children.contains(where: { $0.name == "prev" }) { tieBack = 1 }
        }
        return Note(
            pitch: pitch,
            tpc: tpc,
            accidental: accidental,
            tieForward: tieForward,
            tieBack: tieBack
        )
    }
}
