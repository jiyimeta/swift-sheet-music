import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Encoder-internal description of a Tie spanner's `<location>`
/// payload. MuseScore Studio interprets this in two distinct ways
/// depending on whether `<measures>` is present:
///
/// * `.sameMeasure(fractions:)` — emits `<location><fractions>F</fractions></location>`.
///   MuseScore reads this as a tick delta from the source position
///   to the destination position within the same measure.
///
/// * `.crossMeasure(measures:fractions:)` — emits
///   `<location><measures>M</measures><fractions>F</fractions></location>`
///   (fractions omitted when nil). MuseScore reads this as
///   `(measure delta, position-within-target-measure)`. The
///   `<measures>` token is what disambiguates "this tie crosses a
///   bar line" — without it, MuseScore matches the wrong chord on
///   the source side of the bar, which is what produced the
///   m21→m23 cross-wired ties in `test_export9.mscx`.
enum TieLocation {
    case sameMeasure(fractions: Fraction)
    case crossMeasure(measures: Int, fractions: Fraction?)
}

extension Note {
    /// Build a `<Note>` element. Emits pitch / tpc / optional
    /// accidental / optional headType, plus `<Spanner type="Tie">`
    /// markers for `tieForward` / `tieBack` and a
    /// `<Spanner type="Glissando">` block when `glissando` is set.
    func encode(
        tieForwardLocation: TieLocation? = nil,
        tieBackLocation: TieLocation? = nil,
        options: MSCXEncoderOptions = .init(),
        drumDefaultHead: String? = nil,
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let accidental {
            children.append(XMLTreeNode(
                name: "Accidental",
                children: [
                    XMLTreeNode(
                        name: "subtype",
                        text: accidental.mscxSubtype,
                    ),
                ],
            ))
        }
        if tieForward != nil {
            children.append(tieSpanner(
                side: "next", location: tieForwardLocation,
            ))
        }
        if tieBack != nil {
            children.append(tieSpanner(
                side: "prev", location: tieBackLocation,
            ))
        }
        if let glissando {
            children.append(glissandoSpanner(glissando))
        }
        children.append(XMLTreeNode(name: "pitch", text: String(pitch)))
        children.append(XMLTreeNode(name: "tpc", text: String(tpc)))
        if let headType {
            children.append(XMLTreeNode(name: "head", text: headType))
        } else if let drumDefaultHead {
            children.append(XMLTreeNode(name: "head", text: drumDefaultHead))
        }
        return XMLTreeNode(name: "Note", children: children)
    }

    private func tieSpanner(side: String, location: TieLocation?) -> XMLTreeNode {
        var inner: [XMLTreeNode] = []
        if side == "next" { inner.append(XMLTreeNode(name: "Tie")) }
        var sideChildren: [XMLTreeNode] = []
        if let location {
            sideChildren.append(locationElement(from: location))
        }
        inner.append(XMLTreeNode(name: side, children: sideChildren))
        return XMLTreeNode(
            name: "Spanner",
            attributes: ["type": "Tie"],
            children: inner,
        )
    }

    private func locationElement(from location: TieLocation) -> XMLTreeNode {
        // Element order matches MuseScore Studio's own writer:
        // `<measures>` precedes `<fractions>`. MuseScore's parser
        // appears tolerant of either order, but matching upstream
        // keeps diffs against MuseScore-saved files clean.
        var children: [XMLTreeNode] = []
        switch location {
        case let .sameMeasure(fractions):
            children.append(fractionsNode(fractions))
        case let .crossMeasure(measures, fractions):
            children.append(XMLTreeNode(
                name: "measures", text: String(measures),
            ))
            if let fractions {
                children.append(fractionsNode(fractions))
            }
        }
        return XMLTreeNode(name: "location", children: children)
    }

    private func fractionsNode(_ f: Fraction) -> XMLTreeNode {
        XMLTreeNode(
            name: "fractions",
            text: "\(f.numerator)/\(f.denominator)",
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
            ],
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
                text: visualType == .wavy ? "1" : "0",
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
