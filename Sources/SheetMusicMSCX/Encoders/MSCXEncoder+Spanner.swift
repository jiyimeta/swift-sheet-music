import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Spanner {
    /// Build a `<Spanner type="X">` element. MuseScore writes spanners
    /// as a *pair* — a begin-side carrying the subtype payload (e.g.
    /// `<Volta>`, `<HairPin/>`, `<Slur/>`) plus a `<next>` location to
    /// the end tick, and an end-side placeholder with only `<prev>`.
    ///
    /// We dispatch on `visible`: a begin-side preserves the payload
    /// (and Volta endings / measures offset), an end-side emits just
    /// `<prev/>` so the parser recovers `visible == false`.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if visible {
            children.append(payloadElement())
            if nextMeasuresOffset != 0 {
                children.append(locationWrapper(
                    name: "next", measures: nextMeasuresOffset
                ))
            }
        } else {
            children.append(XMLTreeNode(name: "prev"))
        }
        return XMLTreeNode(
            name: "Spanner",
            attributes: ["type": rawType],
            children: children
        )
    }

    /// The begin-side payload child. MuseScore names this child after
    /// the type — `<Volta>…</Volta>`, `<Slur/>`, `<HairPin/>`, etc.
    /// Volta carries `<endings>` (comma-joined ending numbers); other
    /// kinds are emitted as empty placeholders, since the only fields
    /// the decoder recovers from them are positional.
    private func payloadElement() -> XMLTreeNode {
        if kind == .volta, !voltaEndings.isEmpty {
            let endingsText = voltaEndings.map(String.init).joined(separator: ", ")
            return XMLTreeNode(name: rawType, children: [
                XMLTreeNode(name: "endings", text: endingsText),
            ])
        }
        return XMLTreeNode(name: rawType)
    }

    private func locationWrapper(name: String, measures: Int) -> XMLTreeNode {
        XMLTreeNode(name: name, children: [
            XMLTreeNode(name: "location", children: [
                XMLTreeNode(name: "measures", text: String(measures)),
            ]),
        ])
    }
}
