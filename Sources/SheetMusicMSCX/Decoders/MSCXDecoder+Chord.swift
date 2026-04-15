import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    static func decode(_ node: XMLTreeNode) throws -> Chord {
        guard
            let durationText = node.first("durationType")?.text,
            let baseDuration = NoteDuration(mscxName: durationText)
        else {
            throw SheetMusicError.malformedScore(reason: "Chord missing/invalid <durationType>")
        }
        let dots = Int(node.first("dots")?.text ?? "0") ?? 0
        let duration = baseDuration.dotted(dots)
        let notes = try node.all("Note").map { try Note.decode($0) }

        var arpeggio: Arpeggio?
        if let arpeggioNode = node.first("Arpeggio") {
            let subtype = Int(arpeggioNode.first("subtype")?.text ?? "0") ?? 0
            let stretch = Double(arpeggioNode.first("timeStretch")?.text ?? "1") ?? 1.0
            let userLen = Double(arpeggioNode.first("userLen1")?.text ?? "0") ?? 0.0
            arpeggio = Arpeggio(subtype: subtype, timeStretch: stretch, userLen1: userLen)
        }

        return Chord(duration: duration, notes: notes, arpeggio: arpeggio)
    }
}
