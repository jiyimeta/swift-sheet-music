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
            hairpin = decodeHairpin(hp)
        }

        var ottava: Spanner.OttavaPayload?
        if kind == .ottava, let ot = node.first("Ottava") {
            let subtypeText = ot.first("subtype")?.text ?? "8va"
            ottava = Spanner.OttavaPayload(
                subtype: Spanner.OttavaPayload.Subtype(rawValue: subtypeText),
            )
        }

        var vibrato: Spanner.VibratoPayload?
        if kind == .vibrato, let vib = node.first("Vibrato") {
            let subtypeText = vib.first("subtype")?.text ?? ""
            if let vibratoType = VibratoType(rawValue: subtypeText) {
                vibrato = Spanner.VibratoPayload(type: vibratoType)
            } else {
                mscxDecoderWarn(
                    code: "mscx.vibrato.unknownSubtype",
                    message: "Unknown Vibrato subtype '\(subtypeText)'; defaulting to guitarVibrato",
                )
                vibrato = Spanner.VibratoPayload(type: .guitarVibrato)
            }
        }

        return Spanner(
            kind: kind,
            rawType: raw,
            nextMeasuresOffset: nextMeasures,
            nextFractionsOffset: nextFractions,
            voltaEndings: voltaEndings,
            visible: decodeVisible(node),
            hairpin: hairpin,
            ottava: ottava,
            vibrato: vibrato,
        )
    }

    /// Decode a `<HairPin>` payload. The `<subtype>` is MuseScore's
    /// `HairpinType` (`hairpin.h:32`): 0 cresc wedge, 1 dim wedge,
    /// 2 cresc line, 3 dim line.
    private static func decodeHairpin(
        _ hp: XMLTreeNode,
    ) -> Spanner.HairpinPayload {
        let subtypeRaw = Int(hp.first("subtype")?.text ?? "0") ?? 0
        let subtype: Spanner.HairpinPayload.Subtype
        if let known = Spanner.HairpinPayload.Subtype(rawValue: subtypeRaw) {
            subtype = known
        } else {
            // Embellishment-tier policy: the score still loads, but a
            // hairpin silently flipped to crescendo is exactly the
            // failure this diagnostic exists to surface.
            mscxDecoderWarn(
                code: "mscx.hairpin.unknownSubtype",
                message: "Unknown HairPin subtype \(subtypeRaw); defaulting to crescendo",
            )
            subtype = .crescendo
        }

        let veloChangeText = hp.first("veloChange")?.text
        let veloChangeRaw = veloChangeText.flatMap(Int.init)
        let methodRaw = hp.first("veloChangeMethod")?.text ?? ""

        return Spanner.HairpinPayload(
            subtype: subtype,
            veloChange: veloChangeRaw == 0 ? nil : veloChangeRaw,
            veloChangeMethod: .init(rawValue: methodRaw) ?? .normal,
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
    /// honor either location and treat any `0` as hidden.
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
