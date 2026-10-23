import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Clef {
    /// `isHeader` marks the clef the staff opens with — the caller knows, since it is a matter of where the clef
    /// sits rather than of the clef (`Voice.headerClefIndex(in:)`).
    func encode(eid: EID, isHeader: Bool = false, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        children.append(XMLTreeNode(name: "concertClefType", text: concertClefType))
        // Always written, as MuseScore always writes it: a `<Clef>` naming only the concert type reads back in
        // MuseScore with the transposing one at `ClefTypeList`'s default, G (`TRead::read(Clef*)`), and the
        // transposing type is what MuseScore shows by default — so a bass clef written without it opened as treble.
        children.append(XMLTreeNode(name: "transposingClefType", text: writtenClefType))
        // MuseScore 4.1+ files a `<Clef>` into the `HeaderClef` segment on this tag alone (`read460/measureread.cpp`)
        // and into a `Clef` segment otherwise, which sorts after the key and time signatures — so the staff's opening
        // clef written without it opened as the staff's default clef plus a change after the meter.
        if isHeader {
            children.append(XMLTreeNode(name: "isHeader", text: "1"))
        }
        // `<eid>` sits here, not first: `TWrite::write(const Clef*, ...)`
        // (`rw/write/twrite.cpp:1247-1262`) writes the concert/transposing
        // clef type and `isHeader` (and `isCourtesy`/etc., unmodeled here)
        // before calling `writeItemProperties` — the `<eid>` writer — right
        // where `elementProperties.mscxChildren()` already sits.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Clef", children: children)
    }
}
