import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Measure {
    static func decode(_ node: XMLTreeNode) throws -> Measure {
        let startRepeat = node.children.contains(where: { $0.name == "startRepeat" })
        let endRepeatCount = node.first("endRepeat").flatMap { Int($0.text) }
        let measureRepeatCount = node.first("measureRepeatCount").flatMap { Int($0.text) }

        let voiceNodes = node.all("voice")
        let voices: [Voice]
        if !voiceNodes.isEmpty {
            voices = try voiceNodes.map { try Voice.decode($0) }
        } else {
            // Older / simpler mscx form: musical elements are direct children of
            // <Measure> (no <voice> wrapper). Treat them as a single implicit voice.
            voices = try [Voice.decode(node)]
        }
        let markers = node.all("Marker").map(decodeMarker)
        let jumps = node.all("Jump").map(decodeJump)
        // `<LayoutBreak>` declares an explicit system / page break
        // after this measure. We track `line` (system break) and
        // `page` (page break, which also implies a system break).
        // Section breaks aren't yet plumbed through layout.
        var lineBreak = false
        var pageBreak = false
        for lb in node.all("LayoutBreak") {
            switch lb.first("subtype")?.text {
            case "line": lineBreak = true
            case "page": pageBreak = true
            default: break
            }
        }

        return Measure(
            voices: voices,
            startRepeat: startRepeat,
            endRepeatCount: endRepeatCount,
            measureRepeatCount: measureRepeatCount,
            markers: markers,
            jumps: jumps,
            lineBreak: lineBreak,
            pageBreak: pageBreak
        )
    }

    private static func decodeMarker(_ node: XMLTreeNode) -> Marker {
        let markerType = node.first("markerType")?.text ?? ""
        let label = node.first("label")?.text ?? ""
        let text = node.first("text")?.text ?? ""
        return Marker(
            kind: Marker.Kind(rawValue: markerType) ?? .other,
            label: label,
            text: text
        )
    }

    private static func decodeJump(_ node: XMLTreeNode) -> Jump {
        Jump(
            jumpTo: node.first("jumpTo")?.text ?? "",
            playUntil: node.first("playUntil")?.text ?? "",
            continueAt: node.first("continueAt")?.text ?? "",
            text: node.first("text")?.text ?? ""
        )
    }
}
