import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Measure {
    /// Every `<Marker>` child the decoder reads; the rest is preserved markup.
    static let consumedMarkerChildren: Set = ["label", "markerType", "text"]

    /// A `<Marker>`: its type as MuseScore reads it (`MarkerTypeDecoding`), its label — the type's default when the
    /// file leaves it empty, as MuseScore gives a new marker (`markerTypeTable`, `engraving/dom/marker.cpp:51-62`) —
    /// and its text, the plain projection of `<text>` with the markup preserved.
    static func decodeMarker(_ node: XMLTreeNode) -> Marker {
        let labelNode = node.first("label")
        let rawLabel = labelNode?.text ?? ""
        let textNode = node.first("text")
        // The plain projection: `<text><sym>coda</sym></text>` stays "" — the sym is a glyph, preserved in the markup
        // and drawn from `Marker.richText` — while formatted words (`<b>D.S. al Coda</b>`) keep their characters.
        let text = textNode.map(StaffText.plainText(of:)) ?? ""
        let markup = textNode.flatMap { StaffText.preservedTextMarkup(of: $0, derivedText: text) }
        let kind = MarkerTypeDecoding.kind(
            markerType: node.first("markerType")?.text, label: labelNode?.text, text: text, markup: markup,
            formatRevision: MSCXParserContext.formatRevision,
        )
        return Marker(
            kind: kind,
            label: rawLabel.isEmpty ? kind.defaultLabel : rawLabel,
            text: text,
            preservedMarkup: node.preservedMarkup(consuming: consumedMarkerChildren),
            preservedTextMarkup: markup,
        )
    }
}

/// How MuseScore reads a `<Marker>`'s type, and how this library reads back the spellings it wrote before import
/// fidelity W3.
///
/// - From format 4.60 on, `<markerType>` by MuseScore's names (`Marker.Kind.init(mscxName:)`; unknown names are
///   USER), and FINE — the type's default, which MuseScore never writes — when it is absent
///   (`rw/read460/tread.cpp:1700-1726`, `rw/write/twrite.cpp:2274-2282`).
/// - Before 4.60 no reader looked at `<markerType>`: the type came from `<label>` by the same names, SEGNO when there
///   is no `<label>` (`rw/read410/tread.cpp:1761-1776`, and `read400`, `read206`, `read114`).
/// - A `<markerType>` in a pre-4.60 file can only be this library's own (its 3.02 exports), and is read as one.
enum MarkerTypeDecoding {
    /// The format from which MuseScore reads `<markerType>` (`rw/rwregister.cpp:38-56`).
    private static let markerTypeFormat = 460

    static func kind(
        markerType: String?, label: String?, text: String, markup: PreservedTextMarkup?, formatRevision: Int?,
    ) -> Marker.Kind {
        // Not version-gated, and deliberately opposite to the oracle (a pre-4.60 MuseScore ignores `<markerType>` and
        // reads `<label>`): a `<markerType>` in an older file can only be this library's own 3.02 export.
        if let markerType {
            return kindFromType(markerType, label: label ?? "", text: text, markup: markup)
        }
        if (formatRevision ?? markerTypeFormat) >= markerTypeFormat { return .fine }
        guard let label else { return .segno }
        return Marker.Kind(mscxName: label) ?? .user
    }

    private static func kindFromType(
        _ markerType: String, label: String, text: String, markup: PreservedTextMarkup?,
    ) -> Marker.Kind {
        switch markerType {
        // This library's own spellings before W3, written from `Marker.Kind.rawValue`; MuseScore writes none of them.
        case "toCoda": .toCoda
        case "toCodaSym": .toCodaSym
        case "daCapo": .daCapo
        case "dalSegno": .dalSegno
        case "other": legacyKind(label: label, text: text, markup: markup)
        // MuseScore's To Coda — and this library's old Coda, written with no label or with the default it filled in
        // on reading. A To Coda is labeled `coda` unless renamed. The empty / `codab` label arm is for this library's
        // own older files only, in any format version; MuseScore never writes `coda` with those labels.
        case "coda" where label.isEmpty || label == Marker.Kind.coda.defaultLabel: .coda
        default: Marker.Kind(mscxName: markerType) ?? .user
        }
    }

    /// `other`: a type this library could not name before W3 — Coda, To ⟨coda⟩, Da Coda, Da Doppia Coda, Custom, or a
    /// Fine whose file left `<markerType>` out. The label says which (its MuseScore default, `dom/marker.cpp:51-62`);
    /// the four types labeled `coda` are told apart by their default text.
    private static func legacyKind(label: String, text: String, markup: PreservedTextMarkup?) -> Marker.Kind {
        guard label == Marker.Kind.toCoda.defaultLabel else { return Marker.Kind(mscxName: label) ?? .user }
        switch text.trimmingWhitespaceAndNewlines() {
        case "To Coda": return .toCoda
        case "Da Coda": return .daCoda
        case "Da Doppia Coda": return .daDoubleCoda
        case "To" where markup.map(holdsCoda) ?? false: return .toCodaSym
        default: return .user
        }
    }

    private static func holdsCoda(_ markup: PreservedTextMarkup) -> Bool {
        RichText(markup: markup).lines.joined().contains { run in
            if case .symbol("coda", _) = run { true } else { false }
        }
    }
}
