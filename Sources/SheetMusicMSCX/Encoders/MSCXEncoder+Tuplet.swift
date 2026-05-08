import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Tuplet {
    /// Build the `<Tuplet>` opening marker. `baseDuration` is the
    /// "written" duration of each member (the unscaled `NoteDuration`
    /// — e.g. `eighth` for an eighth-note triplet) and is emitted as
    /// `<baseNote>{name}</baseNote>`. MuseScore 3 requires this child:
    /// without it, `Tuplet::read` leaves `_baseLen` invalid and the
    /// resulting `Fraction(0, 0)` triggers a divide-by-zero in
    /// subsequent tick math (`Ms::Measure::readVoice` SIGFPE crash on
    /// file open). MuseScore 4 already tolerates the field.
    func encode(baseDuration: NoteDuration? = nil) -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "normalNotes", text: String(normalNotes)),
            XMLTreeNode(name: "actualNotes", text: String(actualNotes)),
        ]
        if let baseDuration {
            let baseName = baseDuration.mscxName ?? baseDuration.decomposed()?.name
            if let baseName {
                children.append(XMLTreeNode(name: "baseNote", text: baseName))
            }
        }
        return XMLTreeNode(name: "Tuplet", children: children)
    }
}
