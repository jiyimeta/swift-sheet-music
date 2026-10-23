import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension TupletSpan {
    /// Build the `<Tuplet>` opening marker. `baseDuration` is the tuplet's unit (the written `NoteDuration` it counts
    /// in — e.g. `eighth` for an eighth-note triplet; see `Voice.tupletBaseDuration`) and is emitted as
    /// `<baseNote>{name}</baseNote>`, followed by `<baseDots>` when the unit is dotted, as `TWrite::write(const
    /// Tuplet*, ...)` does. MuseScore takes the tuplet's length from these two, so a wrong or undotted unit makes it
    /// reject the bar as incomplete. MuseScore 3 requires the child: without it, `Tuplet::read` leaves `_baseLen`
    /// invalid and the resulting `Fraction(0, 0)` triggers a divide-by-zero in subsequent tick math
    /// (`Ms::Measure::readVoice` SIGFPE crash on file open).
    ///
    /// `appearance` follows: its element properties, the styled settings it overrides (`<direction>`,
    /// `<numberType>`, `<bracketType>`, written only when set, as MuseScore writes a property only once it is no
    /// longer styled), its preserved markup, and `<color>` last. No `<Number>`: MuseScore makes the number on layout.
    func encode(eid: EID, baseDuration: NoteDuration? = nil, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        // `<eid>` is the true first child: `TWrite::write(const
        // Tuplet*, ...)` (`rw/write/twrite.cpp:3321-3324`) calls
        // `writeItemProperties` before writing `<normalNotes>` /
        // `<actualNotes>` / `<baseNote>` — the opposite of every other
        // text-bearing carrier in this task, but the same shape as
        // KeySig/Sticking/Expression from Task 4a.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children += appearance.elementProperties.mscxChildren()
        children.append(XMLTreeNode(name: "normalNotes", text: String(normalNotes)))
        children.append(XMLTreeNode(name: "actualNotes", text: String(actualNotes)))
        if let base = baseDuration?.decomposed() {
            children.append(XMLTreeNode(name: "baseNote", text: base.name))
            if base.dots > 0 {
                children.append(XMLTreeNode(name: "baseDots", text: String(base.dots)))
            }
        }
        if let direction = appearance.direction {
            children.append(XMLTreeNode(name: "direction", text: direction.mscxText))
        }
        if let numberType = appearance.numberType {
            children.append(XMLTreeNode(name: "numberType", text: String(numberType.rawValue)))
        }
        if let bracketType = appearance.bracketType {
            children.append(XMLTreeNode(name: "bracketType", text: String(bracketType.rawValue)))
        }
        appendPreservedMarkup(appearance.preservedMarkup, to: &children, options: options)
        children += appearance.elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Tuplet", children: children)
    }
}
