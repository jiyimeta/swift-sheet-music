import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Measure {
    /// Build the `<Measure>` element.
    ///
    /// Element ordering matches MuseScore Studio's writer convention:
    /// markers and `<startRepeat/>` come at the head of the measure;
    /// the voices follow; `<endRepeat>` / `<measureRepeatCount>` /
    /// `<Jump>` / `<LayoutBreak>` come at the tail. The decoder is
    /// permissive about ordering so semantic round-trip would work
    /// in any order, but matching MuseScore's order keeps diffs
    /// against fixtures readable.
    func encode() throws -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        for marker in markers {
            children.append(marker.encode())
        }
        if startRepeat {
            children.append(XMLTreeNode(name: "startRepeat"))
        }
        for voice in voices {
            try children.append(voice.encode())
        }
        if let endRepeatCount {
            children.append(XMLTreeNode(
                name: "endRepeat", text: String(endRepeatCount)
            ))
        }
        if let measureRepeatCount {
            children.append(XMLTreeNode(
                name: "measureRepeatCount", text: String(measureRepeatCount)
            ))
        }
        for jump in jumps {
            children.append(jump.encode())
        }
        if lineBreak {
            children.append(XMLTreeNode(
                name: "LayoutBreak",
                children: [XMLTreeNode(name: "subtype", text: "line")]
            ))
        }
        if pageBreak {
            children.append(XMLTreeNode(
                name: "LayoutBreak",
                children: [XMLTreeNode(name: "subtype", text: "page")]
            ))
        }
        return XMLTreeNode(name: "Measure", children: children)
    }
}

extension Marker {
    /// Build a `<Marker>` element matching the decoder in
    /// `MSCXDecoder+Measure.swift`.
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "Marker",
            children: [
                XMLTreeNode(name: "markerType", text: kind.rawValue),
                XMLTreeNode(name: "label", text: label),
                XMLTreeNode(name: "text", text: text),
            ]
        )
    }
}

extension Jump {
    /// Build a `<Jump>` element matching the decoder in
    /// `MSCXDecoder+Measure.swift`.
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "Jump",
            children: [
                XMLTreeNode(name: "jumpTo", text: jumpTo),
                XMLTreeNode(name: "playUntil", text: playUntil),
                XMLTreeNode(name: "continueAt", text: continueAt),
                XMLTreeNode(name: "text", text: text),
            ]
        )
    }
}
