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
        return XMLTreeNode(name: name, children: own + body.children)
    }
}
