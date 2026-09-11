import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Fermata {
    /// Build a `<Fermata>` element. Mirrors the inline fermata
    /// decoding in `MSCXDecoder+Voice.swift`. `<timeStretch>` is
    /// omitted when the value matches the subtype's default — same
    /// "omit when default" convention MuseScore uses.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        children.append(XMLTreeNode(name: "subtype", text: subtype))
        let defaultStretch = Fermata.defaultTimeStretch(for: subtype)
        if timeStretch != defaultStretch {
            children.append(XMLTreeNode(
                name: "timeStretch",
                text: formatStretch(timeStretch),
            ))
        }
        // `<eid>` sits here, not first: `TWrite::write(const Fermata*, ...)`
        // (`rw/write/twrite.cpp:1353-1368`) writes `<subtype>`/`<timeStretch>`
        // (and other unmodeled properties) before calling
        // `writeItemProperties` — the `<eid>` writer — right where
        // `elementProperties.mscxChildren()` already sits.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Fermata", children: children)
    }

    /// MuseScore writes whole numbers without a trailing `.0` and
    /// fractional values with their natural representation; mimic
    /// that to keep MSCX diffs readable. Examples: 2.0 → "2",
    /// 1.25 → "1.25".
    private func formatStretch(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(value)
    }
}
