import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    /// Encode as a `<Chord>` (notes-bearing). Caller must guarantee
    /// `notes.isEmpty == false`; voice-level dispatch routes empty
    /// chords through `encodeAsRest()` instead.
    ///
    /// `tieForwardLocation` / `tieBackLocation` describe the
    /// `<Spanner type="Tie"><location>` payload for ties on this
    /// chord. `Voice.encode` decides which form to use based on
    /// whether the partner chord lives in the same measure or
    /// crosses the bar line.
    func encodeAsChord(
        tieForwardLocation: TieLocation? = nil,
        tieBackLocation: TieLocation? = nil
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        for note in notes {
            children.append(note.encode(
                tieForwardLocation: tieForwardLocation,
                tieBackLocation: tieBackLocation
            ))
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
