import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Note {
    /// Build a `<Note>` element. Emits pitch / tpc / optional
    /// accidental / optional headType, plus `<Spanner type="Tie">`
    /// markers for `tieForward` / `tieBack` and a
    /// `<Spanner type="Glissando">` block when `glissando` is set.
    /// The decoder recovers tie/glissando flags from the presence of
    /// `<next>` / `<prev>` and the inner `<Glissando>` payload — no
    /// cross-note location math is required.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let accidental {
            children.append(XMLTreeNode(
                name: "Accidental",
                children: [
                    XMLTreeNode(
                        name: "subtype",
                        text: accidental.mscxSubtype
                    ),
                ]
            ))
        }
        if tieForward != nil {
            children.append(tieSpanner(side: "next"))
        }
        if tieBack != nil {
            children.append(tieSpanner(side: "prev"))
        }
        if let glissando {
            children.append(glissandoSpanner(glissando))
        }
        children.append(XMLTreeNode(name: "pitch", text: String(pitch)))
        children.append(XMLTreeNode(name: "tpc", text: String(tpc)))
        if let headType {
            children.append(XMLTreeNode(name: "head", text: headType))
        }
        return XMLTreeNode(name: "Note", children: children)
    }

    private func tieSpanner(side: String) -> XMLTreeNode {
        // `<Spanner type="Tie"><Tie/><next/></Spanner>` for the
        // start, `<Spanner type="Tie"><prev/></Spanner>` for the end.
        // Decoder keys off the bare presence of `<next>` / `<prev>`
        // — location values are not consulted.
        var inner: [XMLTreeNode] = []
        if side == "next" { inner.append(XMLTreeNode(name: "Tie")) }
        inner.append(XMLTreeNode(name: side))
        return XMLTreeNode(
            name: "Spanner",
            attributes: ["type": "Tie"],
            children: inner
        )
    }

    private func glissandoSpanner(_ glissando: Glissando) -> XMLTreeNode {
        // Start-side only — the end note carries no model state, and
        // the decoder ignores `<Spanner type="Glissando">` blocks
        // without a `<Glissando>` payload child.
        XMLTreeNode(
            name: "Spanner",
            attributes: ["type": "Glissando"],
            children: [
                glissando.encode(),
                XMLTreeNode(name: "next"),
            ]
        )
    }
}

extension Glissando {
    /// Build the `<Glissando>` payload child of a
    /// `<Spanner type="Glissando">`. Mirrors MuseScore 4's
    /// `TWrite::write(const Glissando*, …)` — uppercase style token,
    /// `easeInSpin` / `easeOutSpin` integers, `subtype` 0/1 for
    /// straight/wavy, optional `<text>`.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(
                name: "subtype",
                text: visualType == .wavy ? "1" : "0"
            ),
            XMLTreeNode(name: "glissandoStyle", text: style.mscxToken),
            XMLTreeNode(name: "easeInSpin", text: String(easeIn)),
            XMLTreeNode(name: "easeOutSpin", text: String(easeOut)),
        ]
        if let text, !text.isEmpty {
            children.append(XMLTreeNode(name: "text", text: text))
        }
        return XMLTreeNode(name: "Glissando", children: children)
    }
}

extension Glissando.Style {
    /// MuseScore writes these as ALL-CAPS tokens; the decoder accepts
    /// any case but we mirror the writer's output.
    var mscxToken: String {
        switch self {
        case .chromatic: "CHROMATIC"
        case .diatonic: "DIATONIC"
        case .whiteKeys: "WHITE_KEYS"
        case .blackKeys: "BLACK_KEYS"
        case .portamento: "PORTAMENTO"
        }
    }
}

extension Accidental {
    /// Mirror of `Accidental.init?(mscxSubtype:)` — exhaustive.
    var mscxSubtype: String {
        switch self {
        case .sharp: "accidentalSharp"
        case .flat: "accidentalFlat"
        case .natural: "accidentalNatural"
        case .doubleSharp: "accidentalDoubleSharp"
        case .doubleFlat: "accidentalDoubleFlat"
        }
    }
}
