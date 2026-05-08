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
    /// (and Volta endings / measures + fractions offsets), an
    /// end-side emits just `<prev/>` so the parser recovers
    /// `visible == false`.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if visible {
            children.append(payloadElement(options: options))
            if let next = nextLocationElement(options: options) {
                children.append(next)
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
    private func payloadElement(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        if kind == .volta, !voltaEndings.isEmpty {
            let endingsText = voltaEndings.map(String.init).joined(separator: ", ")
            return XMLTreeNode(name: rawType, children: [
                XMLTreeNode(name: "endings", text: endingsText),
            ])
        }
        return XMLTreeNode(name: rawType)
    }

    /// `<next><location>…</location></next>`. Returns nil when both
    /// offsets are at their defaults (no end-side anchor needed).
    /// Element order inside `<location>`: `<fractions>` then
    /// `<measures>`, mirroring MuseScore's writer
    /// (`engraving/types/location.cpp::Location::write`).
    private func nextLocationElement(options: MSCXEncoderOptions = .init()) -> XMLTreeNode? {
        var locationChildren: [XMLTreeNode] = []
        if let frac = nextFractionsOffset {
            locationChildren.append(XMLTreeNode(
                name: "fractions",
                text: "\(frac.numerator)/\(frac.denominator)"
            ))
        }
        if nextMeasuresOffset != 0 {
            locationChildren.append(XMLTreeNode(
                name: "measures",
                text: String(nextMeasuresOffset)
            ))
        }
        guard !locationChildren.isEmpty else { return nil }
        return XMLTreeNode(name: "next", children: [
            XMLTreeNode(name: "location", children: locationChildren),
        ])
    }
}
