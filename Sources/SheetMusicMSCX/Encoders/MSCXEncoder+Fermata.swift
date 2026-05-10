import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Fermata {
    /// Build a `<Fermata>` element. Mirrors the inline fermata
    /// decoding in `MSCXDecoder+Voice.swift`. `<timeStretch>` is
    /// omitted when the value matches the subtype's default — same
    /// "omit when default" convention MuseScore uses.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: subtype),
        ]
        let defaultStretch = Fermata.defaultTimeStretch(for: subtype)
        if timeStretch != defaultStretch {
            children.append(XMLTreeNode(
                name: "timeStretch",
                text: formatStretch(timeStretch)
            ))
        }
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
