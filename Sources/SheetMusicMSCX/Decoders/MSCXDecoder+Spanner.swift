import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Spanner {
    /// Wrapper children every spanner decoder consumes. The payload
    /// child is named by the `type` attribute, so `decode(_:)` adds
    /// that runtime name before capturing anything else.
    private static let consumedSpannerChildren: Set = [
        "next", "prev", "visible",
    ]

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

        let hairpin = kind == .hairpin ? node.first("HairPin").map(decodeHairpin) : nil

        var ottava: Spanner.OttavaPayload?
        if kind == .ottava, let ot = node.first("Ottava") {
            let subtypeText = ot.first("subtype")?.text ?? "8va"
            ottava = Spanner.OttavaPayload(
                subtype: Spanner.OttavaPayload.Subtype(rawValue: subtypeText),
                numbersOnly: ot.first("numbersOnly").map { $0.text != "0" },
            )
        }

        let vibrato = kind == .vibrato ? node.first("Vibrato").map(decodeVibrato) : nil

        var trill: Spanner.TrillPayload?
        if kind == .trill, let tr = node.first("Trill") {
            trill = decodeTrill(tr)
        }
        let gradualTempoChange = kind == .gradualTempoChange ? node.first(raw).map(decodeGradualTempoChange) : nil

        let elementProperties = decodeElementProperties(node, payloadName: raw)
        var spanner = Spanner(
            kind: kind,
            rawType: raw,
            nextMeasuresOffset: nextMeasures,
            nextFractionsOffset: nextFractions,
            voltaEndings: voltaEndings,
            visible: elementProperties.visible,
            beginText: decodeLineText(node, named: "beginText"),
            placement: elementProperties.placement,
            hairpin: hairpin,
            ottava: ottava,
            vibrato: vibrato,
            trill: trill,
            gradualTempoChange: gradualTempoChange,
            continueText: decodeLineText(node, named: "continueText"),
            endText: decodeLineText(node, named: "endText"),
            preservedMarkup: node.preservedMarkup(
                consuming: consumedSpannerChildren.union([raw]),
            ),
        )
        spanner.elementProperties = elementProperties
        return spanner
    }

    private static func decodeVibrato(_ vib: XMLTreeNode) -> Spanner.VibratoPayload {
        let subtypeText = vib.first("subtype")?.text ?? ""
        if let vibratoType = VibratoType(rawValue: subtypeText) {
            return Spanner.VibratoPayload(type: vibratoType)
        }
        mscxDecoderWarn(
            code: "mscx.vibrato.unknownSubtype",
            message: "Unknown Vibrato subtype '\(subtypeText)'; defaulting to guitarVibrato",
        )
        return Spanner.VibratoPayload(type: .guitarVibrato)
    }

    /// A `TextLineBase` text property — `<beginText>`, `<continueText>`, `<endText>` — lives on the subtype payload
    /// child, not on the `<Spanner>` wrapper, and MuseScore writes it on any `TextLineBase` subclass — so scan every
    /// payload child rather than special-casing `<TextLine>`. `next` / `prev` are location records and never carry
    /// one. Unlike `decodeVisible` below, this walk has no `<eid>` exclusion: `child.first(name)` on an `<eid>` leaf
    /// node (no children of its own) is always nil, so the wrapper's identifier is harmless here without
    /// special-casing it — the asymmetry with `decodeVisible` is not accidental.
    private static func decodeLineText(_ node: XMLTreeNode, named name: String) -> String? {
        for child in node.children
            where child.name != "next" && child.name != "prev"
        {
            if let text = child.first(name)?.text, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// The children `decodeGradualTempoChange` and the spanner itself read off the payload — its own properties
    /// (`TWrite::write(const GradualTempoChange*)`, `rw/write/twrite.cpp:1651-1661`), the three line texts and the
    /// element properties — so the payload's bag keeps exactly the rest.
    private static let consumedGradualTempoChangeChildren: Set = [
        "tempoChangeType", "tempoEasingMethod", "tempoChangeFactor", "play",
        "beginText", "continueText", "endText",
        "visible", "color", "offset", "placement", "autoplace",
    ]

    /// Decode a `<GradualTempoChange>` payload. An absent `<tempoChangeType>` is MuseScore's `Undefined`, an absent
    /// `<tempoChangeFactor>` the type's default, an absent `<tempoEasingMethod>` `normal` (`gradualtempochange.cpp:
    /// 243-248`).
    private static func decodeGradualTempoChange(_ payload: XMLTreeNode) -> Spanner.GradualTempoChangePayload {
        Spanner.GradualTempoChangePayload(
            type: payload.first("tempoChangeType").flatMap { GradualTempoChangeType(rawValue: $0.text) } ?? .undefined,
            factor: payload.first("tempoChangeFactor").flatMap { Double($0.text) },
            easing: payload.first("tempoEasingMethod").flatMap { Spanner.ChangeMethod(rawValue: $0.text) } ?? .normal,
            playsBack: (payload.first("play").flatMap { Int($0.text) } ?? 1) != 0,
            preservedMarkup: payload.preservedMarkup(consuming: consumedGradualTempoChangeChildren),
        )
    }

    /// Base properties ride on the payload child (`<Volta>`, `<Slur>`, …),
    /// while a wrapper-level `<visible>0</visible>` is also accepted for
    /// compatibility. The end-side `<prev>` marker has no payload and uses
    /// the same visibility rule as before.
    private static func decodeElementProperties(
        _ node: XMLTreeNode,
        payloadName: String,
    ) -> ElementProperties {
        let payload = node.first(payloadName)
        var properties = payload.map(ElementProperties.init(decodingMSCXChildrenOf:))
            ?? .default
        properties.visible = decodeVisible(node)
        return properties
    }

    /// Decode a `<Trill>` payload. MuseScore omits `<subtype>` for the
    /// default trill line, so an absent element means `.trill`.
    private static func decodeTrill(
        _ tr: XMLTreeNode,
    ) -> Spanner.TrillPayload {
        let subtypeText = tr.first("subtype")?.text ?? "trill"
        guard let trillType = TrillType(rawValue: subtypeText) else {
            mscxDecoderWarn(
                code: "mscx.trill.unknownSubtype",
                message: "Unknown Trill subtype '\(subtypeText)'; defaulting to trill",
            )
            return Spanner.TrillPayload(type: .trill)
        }
        return Spanner.TrillPayload(type: trillType)
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
            // `<eid>` is the wrapper's own identifier (see `EIDXML`), not a subtype payload.
            // `.spanner` was reverted to `.invalid` (Task 4a) and `Spanner.encode` writes no
            // `<eid>` of its own, and real MuseScore never puts one on the `<Spanner>` wrapper
            // either — so nothing should reach this exclusion today. Kept as defensive: some
            // intermediate commit of this phase did write that shape on the wrapper, and
            // counting it here would have made every invisible end marker decode back as
            // visible the moment it carried an identifier.
            where child.name != "next" && child.name != "prev" && child.name != EIDXML.childName
        {
            hasPayload = true
            if child.first("visible")?.text == "0" { return false }
        }
        return hasPayload
    }
}
