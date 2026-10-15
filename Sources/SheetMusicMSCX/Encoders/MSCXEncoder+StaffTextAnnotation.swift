import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StaffText {
    /// An annotated staff text as MuseScore 4 writes it: the element's own properties first, each omitted at its
    /// default (`TWrite::write(PlayTechAnnotation*)`, `rw/write/twrite.cpp:2614-2620`;
    /// `TWrite::write(HarpPedalDiagram*)`, `twrite.cpp:1853-1870`), then the text properties a staff text writes.
    /// `nil` for an ordinary staff text.
    func encodeAnnotation(eid: EID, options: MSCXEncoderOptions) -> XMLTreeNode? {
        guard let annotation else { return nil }
        var plain = self
        plain.annotation = nil
        let body = plain.encode(eid: eid, options: options)
        let name: String
        let own: [XMLTreeNode]
        switch annotation {
        case let .playTechnique(technique, playsBack):
            name = "PlayTechAnnotation"
            var children: [XMLTreeNode] = []
            if technique != .natural {
                children.append(XMLTreeNode(name: "playTechType", text: technique.mscxToken))
            }
            if !playsBack {
                children.append(XMLTreeNode(name: "play", text: "0"))
            }
            own = children
        case let .harpPedal(diagram):
            name = "HarpPedalDiagram"
            var children: [XMLTreeNode] = []
            if !diagram.isDiagram {
                children.append(XMLTreeNode(name: "isDiagram", text: "0"))
            }
            children.append(XMLTreeNode(
                name: "pedalState",
                children: diagram.pedals.enumerated().map { index, position in
                    XMLTreeNode(name: "string", attributes: ["name": "\(index)"], text: "\(position.mscxOrdinal)")
                },
            ))
            own = children
        }
        // The unmodeled children go right after `<eid>`: MuseScore writes `<style>` after the item properties and
        // before the overrides (`TWrite::writeProperties(TextBase*)`, `twrite.cpp:1320-1335`), and reading `<style>`
        // re-applies the style, so it must come before the offset and font children this encoder writes.
        var children = body.children
        if options.emitPreservedMarkup, !annotationMarkup.isEmpty {
            let afterEID = children.first?.name == EIDXML.childName ? 1 : 0
            let written = Set(children.map(\.name))
            let kept = annotationMarkup.filter { !written.contains($0.name) }.map(XMLTreeNode.init(preserved:))
            children.insert(contentsOf: kept, at: afterEID)
        }
        return XMLTreeNode(name: name, children: own + children)
    }
}
