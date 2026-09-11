import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension TupletSpan {
    /// Build the `<Tuplet>` opening marker. `baseDuration` is the
    /// "written" duration of each member (the unscaled `NoteDuration`
    /// — e.g. `eighth` for an eighth-note triplet) and is emitted as
    /// `<baseNote>{name}</baseNote>`. MuseScore 3 requires this child:
    /// without it, `Tuplet::read` leaves `_baseLen` invalid and the
    /// resulting `Fraction(0, 0)` triggers a divide-by-zero in
    /// subsequent tick math (`Ms::Measure::readVoice` SIGFPE crash on
    /// file open). MuseScore 4 already tolerates the field.
    func encode(eid: EID, baseDuration: NoteDuration? = nil, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        // `<eid>` is the true first child: `TWrite::write(const
        // Tuplet*, ...)` (`rw/write/twrite.cpp:3321-3324`) calls
        // `writeItemProperties` before writing `<normalNotes>` /
        // `<actualNotes>` / `<baseNote>` — the opposite of every other
        // text-bearing carrier in this task, but the same shape as
        // KeySig/Sticking/Expression from Task 4a.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(XMLTreeNode(name: "normalNotes", text: String(normalNotes)))
        children.append(XMLTreeNode(name: "actualNotes", text: String(actualNotes)))
        if let baseDuration {
            let baseName = baseDuration.mscxName ?? baseDuration.decomposed()?.name
            if let baseName {
                children.append(XMLTreeNode(name: "baseNote", text: baseName))
            }
        }
        return XMLTreeNode(name: "Tuplet", children: children)
    }
}
