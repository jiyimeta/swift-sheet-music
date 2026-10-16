import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension FretDiagram {
    /// The diagram's own properties MuseScore writes before `<eid>`, in its order (`TWrite::write(const
    /// FretDiagram*)`, `rw/write/twrite.cpp:1445-1461`); the ones this model does not represent ride in preserved
    /// markup and are written in their slot here — never after `<fretDiagram>`, where MuseScore's reader skips them.
    private static let propertyOrder = [
        "minDistance", "fretOffset", "frets", "strings", "showNut", "mag", "orientation", "showFingering",
        "fingering", "excludeVerticalAlign",
    ]

    /// Build the `<FretDiagram>` element in MuseScore's storage order.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        let leading = preservedMarkup.filter { Self.propertyOrder.contains($0.name) }
        let trailing = preservedMarkup.filter { !Self.propertyOrder.contains($0.name) }
        for property in Self.propertyOrder {
            switch property {
            case "fretOffset":
                if let fretOffset { children.append(XMLTreeNode(name: "fretOffset", text: String(fretOffset))) }
            case "frets":
                children.append(XMLTreeNode(name: "frets", text: String(fretCount)))
            case "strings":
                children.append(XMLTreeNode(name: "strings", text: String(stringCount)))
            case "showNut":
                if let showNut { children.append(XMLTreeNode(name: "showNut", text: showNut ? "1" : "0")) }
            case "orientation":
                if let orientation {
                    children.append(XMLTreeNode(name: "orientation", text: orientation.mscxText))
                }
            default:
                appendPreservedMarkup(leading.filter { $0.name == property }, to: &children, options: options)
            }
        }
        // `<eid>` sits here, not first: `TWrite::write(const FretDiagram*,
        // ...)` (`rw/write/twrite.cpp:1438-1465`) writes its own properties
        // loop (which includes the strings/frets counts) before calling
        // `writeItemProperties` — the `<eid>` writer — and only THEN writes
        // `<Harmony>` and the `<fretDiagram>` payload; right where
        // `elementProperties.mscxChildren()` already sits.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children += elementProperties.mscxChildren()
        children += elementProperties.mscxTrailingChildren()
        if let harmony {
            // The embedded chord symbol has no slot of its own — it is a
            // property of this `FretDiagram`, not an `IdentifiedArray`
            // element — so it carries no identifier of its own to persist.
            children.append(harmony.encode(eid: .invalid, options: options))
        }
        children.append(encodeContents())
        // Invariant: nothing follows `<fretDiagram>` except preserved markup.
        // MuseScore's reader skips every later child; its writer puts the old
        // compatibility block there.
        appendPreservedMarkup(trailing, to: &children, options: options)
        return XMLTreeNode(name: "FretDiagram", children: children)
    }

    private func encodeContents() -> XMLTreeNode {
        var children = strings.map { string in
            var stringChildren: [XMLTreeNode] = []
            if let marker = string.marker {
                stringChildren.append(XMLTreeNode(name: "marker", text: marker.mscxToken))
            }
            stringChildren += string.dots.map { dot in
                XMLTreeNode(
                    name: "dot",
                    attributes: ["fret": String(dot.fret)],
                    text: dot.kind.mscxToken,
                )
            }
            return XMLTreeNode(
                name: "string",
                attributes: ["no": String(string.index)],
                children: stringChildren,
            )
        }
        // MuseScore keeps barres in a fret-keyed map and writes them in ascending fret order.
        for barre in barres.enumerated().sorted(by: { ($0.element.fret, $0.offset) < ($1.element.fret, $1.offset) }) {
            children.append(XMLTreeNode(
                name: "barre",
                attributes: [
                    "start": String(barre.element.startString),
                    "end": String(barre.element.endString),
                ],
                text: String(barre.element.fret),
            ))
        }
        return XMLTreeNode(name: "fretDiagram", children: children)
    }
}
