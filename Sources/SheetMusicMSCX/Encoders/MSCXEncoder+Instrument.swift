import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Instrument {
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let longName {
            children.append(XMLTreeNode(name: "longName", text: longName))
        }
        if let shortName {
            children.append(XMLTreeNode(name: "shortName", text: shortName))
        }
        if let trackName {
            children.append(XMLTreeNode(name: "trackName", text: trackName))
        }
        if let v = minPitchPlayable {
            children.append(XMLTreeNode(name: "minPitchP", text: String(v)))
        }
        if let v = maxPitchPlayable {
            children.append(XMLTreeNode(name: "maxPitchP", text: String(v)))
        }
        if let v = minPitchAmateur {
            children.append(XMLTreeNode(name: "minPitchA", text: String(v)))
        }
        if let v = maxPitchAmateur {
            children.append(XMLTreeNode(name: "maxPitchA", text: String(v)))
        }
        if useDrumset {
            children.append(XMLTreeNode(name: "useDrumset", text: "1"))
        }
        for pitch in drumLineMap.keys.sorted() {
            children.append(XMLTreeNode(
                name: "Drum",
                attributes: ["pitch": String(pitch)],
                children: [
                    XMLTreeNode(name: "line", text: String(drumLineMap[pitch] ?? 0)),
                ]
            ))
        }
        for art in articulations {
            children.append(art.encode())
        }
        for chan in channels {
            children.append(chan.encode())
        }
        return XMLTreeNode(
            name: "Instrument",
            attributes: ["id": id],
            children: children
        )
    }
}
