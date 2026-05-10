import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Measure {
    /// True when a raw `<Measure>` XML node is MuseScore's mmRest
    /// "annotation container" (`<Measure len="K×ts"><multiMeasureRest>K>`)
    /// rather than a real bar.
    ///
    /// MuseScore writes a K-bar multi-measure rest as K+1 sibling
    /// `<Measure>` entries: one regular rest measure leading the run,
    /// the mmRest container, then K-1 regular rest measures trailing.
    /// The container's own `<voice>` carries an oddly-shaped rest
    /// (e.g. `<duration>8/4>` for any K) — it isn't a bar, just the
    /// "this run of K rest bars renders as one H-bar with the number
    /// K above" hint that older readers used to lay out the visual.
    ///
    /// Counting it as a bar inflates the bar count by one per mmRest
    /// section (m111-115 instead of m111-114 for a 4-bar group). The
    /// surrounding K real rest measures are kept; the layout-time
    /// `MultiMeasureRestPlanner` collapses them on demand.
    static func isMultiMeasureRestContainer(_ node: XMLTreeNode) -> Bool {
        node.children.contains(where: { $0.name == "multiMeasureRest" })
    }

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

        // `<Measure len="N/D">` — actual length when it differs from
        // the prevailing time signature. Malformed values fall back to
        // nil; the parser stays permissive about optional metadata.
        let actualLength = node.attributes["len"]
            .flatMap(Fraction.init(mscxString:))
        // `<irregular>1</irregular>` — exclude this measure from the
        // running displayed measure number (typical on anacrusis).
        let irregular = node.first("irregular")?.text == "1"

        return Measure(
            voices: voices,
            startRepeat: startRepeat,
            endRepeatCount: endRepeatCount,
            measureRepeatCount: measureRepeatCount,
            markers: markers,
            jumps: jumps,
            lineBreak: lineBreak,
            pageBreak: pageBreak,
            actualLength: actualLength,
            irregular: irregular
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
