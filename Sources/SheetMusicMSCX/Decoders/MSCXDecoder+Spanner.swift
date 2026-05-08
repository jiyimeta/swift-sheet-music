import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Spanner {
    static func decode(_ node: XMLTreeNode) throws -> Spanner {
        let raw = node.attributes["type"] ?? ""
        let kind = Kind(rawValue: raw) ?? .other

        var voltaEndings: [Int] = []
        if let voltaNode = node.first("Volta") {
            let endingsText = voltaNode.first("endings")?.text ?? ""
            voltaEndings = endingsText
                .split(whereSeparator: { ", ".contains($0) })
                .compactMap { Int($0) }
        }

        let nextLocation = node.first("next")?.first("location")
        let nextMeasures = Int(nextLocation?.first("measures")?.text ?? "0") ?? 0
        let nextFractions = nextLocation?.first("fractions")
            .flatMap { Fraction(mscxString: $0.text) }

        var hairpin: Spanner.HairpinPayload?
        if kind == .hairpin, let hp = node.first("HairPin") {
            let subtypeRaw = Int(hp.first("subtype")?.text ?? "0") ?? 0
            let subtype = Spanner.HairpinPayload.Subtype(rawValue: subtypeRaw) ?? .crescendo

            let veloChangeText = hp.first("veloChange")?.text
            let veloChangeRaw = veloChangeText.flatMap(Int.init)
            let veloChange = veloChangeRaw == 0 ? nil : veloChangeRaw

            let methodRaw = hp.first("veloChangeMethod")?.text ?? ""
            let method = Spanner.HairpinPayload.VeloChangeMethod(rawValue: methodRaw) ?? .normal

            hairpin = Spanner.HairpinPayload(
                subtype: subtype,
                veloChange: veloChange,
                veloChangeMethod: method
            )
        }

        return Spanner(
            kind: kind,
            rawType: raw,
            nextMeasuresOffset: nextMeasures,
            nextFractionsOffset: nextFractions,
            voltaEndings: voltaEndings,
            visible: decodeVisible(node),
            hairpin: hairpin
        )
    }

    /// MuseScore writes a spanner as a *pair* of `<Spanner>` elements
    /// — the begin-side carries the subtype payload (`<Pedal>`,
    /// `<HairPin>`, `<Volta>`, ...) plus a `<next>` location to the
    /// end tick; the end-side is a placeholder with only a `<prev>`
    /// location pointing back. The end-side has no own glyph and
    /// would otherwise emit a duplicate zero-length anchor at the
    /// end tick — treat it as hidden so the layout filter drops it.
    ///
    /// On the begin-side, MuseScore stores `<visible>0</visible>` on
    /// the inner subtype child (not on the `<Spanner>` wrapper). We
    /// honour either location and treat any `0` as hidden.
    private static func decodeVisible(_ node: XMLTreeNode) -> Bool {
        if (node.first("visible")?.text ?? "1") == "0" { return false }
        var hasPayload = false
        for child in node.children
            where child.name != "next" && child.name != "prev"
        {
            hasPayload = true
            if child.first("visible")?.text == "0" { return false }
        }
        return hasPayload
    }
}
