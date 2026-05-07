import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    /// Encode as a `<Chord>` (notes-bearing). Caller must guarantee
    /// `notes.isEmpty == false`; voice-level dispatch routes empty
    /// chords through `encodeAsRest()` instead.
    func encodeAsChord() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        for note in notes {
            children.append(note.encode())
        }
        return XMLTreeNode(name: "Chord", children: children)
    }

    /// Encode as a `<Rest>` (notes-empty representation).
    func encodeAsRest() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        return XMLTreeNode(name: "Rest", children: children)
    }
}
