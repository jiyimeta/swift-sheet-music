import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Spanner {
    /// The kinds whose begin-side payload child carries `TextLineBase` properties
    /// (`TWrite::writeProperties(TextLineBase)`, `rw/write/twrite.cpp:1663-1672`).
    static let lineVariantKinds: Set<Kind> = [
        .pedal, .textLine, .palmMute, .letRing, .chordTextLine, .hairpin, .volta,
    ]

    /// The `TextLineBase` tags `decodeLineProperties` reads (tag names `dom/property.cpp:230-231,269,295-296,351-352,
    /// 383`), and `<play>` (`Spanner::playSpanner`).
    private static let linePropertyTags: Set = [
        "beginHookType", "endHookType", "lineVisible", "lineStyle", "dashLineLength", "dashGapLength", "lineWidth",
        "beginHookHeight", "endHookHeight", "play",
    ]

    /// The line texts and element properties the encoder writes itself around every payload (`payloadElement`).
    private static let consumedLineChildren: Set = [
        "beginText", "continueText", "endText",
        "visible", "color", "offset", "placement", "autoplace",
    ]

    /// The payload children this decoder reads for `kind` — the line texts, the element properties, the modeled line
    /// tags and, per kind, the ones the encoder writes from its own model (hairpin `subtype`, `veloChange`,
    /// `veloChangeMethod`, `voiceAssignment` and the older `dynType`; volta `endings`). The payload's bag keeps
    /// exactly the rest. `unread` names line tags the decoder could not parse: they stay in the bag.
    static func consumedPayloadChildren(for kind: Kind, unread: Set<String> = []) -> Set<String> {
        var consumed = consumedLineChildren
        guard lineVariantKinds.contains(kind) else { return consumed }
        consumed.formUnion(linePropertyTags.subtracting(unread))
        switch kind {
        case .hairpin:
            consumed.formUnion(["subtype", "veloChange", "veloChangeMethod", "voiceAssignment", "dynType"])
        case .volta:
            consumed.insert("endings")
        default:
            break
        }
        return consumed
    }

    /// A begin side's payload child: the line variants it carries and the children nothing models. Kinds with their
    /// own payload path (slur, ottava, trill, vibrato, glissando, gradual tempo) keep it and keep no bag. A payload
    /// that sets no line property is `nil` — the value a spanner made in code carries — so a save round-trips it.
    static func decodeLinePayload(
        _ payload: XMLTreeNode?, kind: Kind,
    ) -> (lineProperties: LineProperties?, payloadMarkup: [PreservedXML]) {
        guard let payload, lineVariantKinds.contains(kind) || kind == .other else { return (nil, []) }
        var lineProperties: LineProperties?
        var unread: Set<String> = []
        if lineVariantKinds.contains(kind) {
            let decoded = decodeLineProperties(payload)
            lineProperties = decoded.properties == LineProperties() ? nil : decoded.properties
            unread = decoded.unread
        }
        return (lineProperties, payload.preservedMarkup(consuming: consumedPayloadChildren(for: kind, unread: unread)))
    }

    /// Read the `TextLineBase` tags of a payload child. MuseScore writes each only when it differs from the item's
    /// default, so an absent tag stays `nil` ("the kind's default"). A tag whose text does not parse, or an unknown
    /// `<lineStyle>` code, is left unread and returned in `unread` so it stays in the payload's bag.
    static func decodeLineProperties(_ payload: XMLTreeNode) -> (properties: LineProperties, unread: Set<String>) {
        var unread: Set<String> = []
        func int(_ name: String) -> Int? {
            guard let text = payload.first(name)?.text else { return nil }
            guard let value = Int(text.trimmingWhitespaceAndNewlines()) else {
                unread.insert(name)
                return nil
            }
            return value
        }
        func double(_ name: String) -> Double? {
            guard let text = payload.first(name)?.text else { return nil }
            guard let value = Double(text.trimmingWhitespaceAndNewlines()) else {
                unread.insert(name)
                return nil
            }
            return value
        }
        let lineType = int("lineStyle").flatMap { code -> LineType? in
            let known = LineType(rawValue: code)
            if known == nil { unread.insert("lineStyle") }
            return known
        }
        let properties = LineProperties(
            beginHook: int("beginHookType").map(LineHookType.init(code:)),
            endHook: int("endHookType").map(LineHookType.init(code:)),
            beginHookHeight: double("beginHookHeight"),
            endHookHeight: double("endHookHeight"),
            lineVisible: int("lineVisible").map { $0 != 0 },
            lineType: lineType,
            dashLength: double("dashLineLength"),
            dashGap: double("dashGapLength"),
            lineWidth: double("lineWidth"),
            playsBack: (int("play") ?? 1) != 0,
        )
        return (properties, unread)
    }
}
