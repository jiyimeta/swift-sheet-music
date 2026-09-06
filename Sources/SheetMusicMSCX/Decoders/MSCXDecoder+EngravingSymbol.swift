import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension EngravingSymbol {
    /// Every direct `<Symbol>` child this decoder reads. Nested `<Symbol>` and
    /// `<Image>` children, `BSymbol` properties, and anything else become
    /// preserved markup.
    ///
    /// MuseScore 4.6 accepts both `<font>` and `<scoreFont>` as
    /// `Pid::SCORE_FONT`; the property's XML name is `scoreFont`
    /// (`dom/property.cpp:500`). Only `<font>` is consumed here. Folding the
    /// alias into `scoreFont` and writing it back as `<font>` would change the
    /// input shape and make the preservation gate report a false loss. This is
    /// the same parity decision that leaves MuseScore 3 ornament-shaped
    /// `<Articulation>` values as `ChordArticulation.unknown`.
    /// The base `<offset>` and `<placement>` are owned by `ElementProperties`,
    /// not preserved here.
    private static let consumedChildren: Set = [
        "name", "font", "symbolsSize", "symbolAngle",
        "color", "offset", "placement", "visible",
    ]

    /// Decode direct `<Symbol>` children of a `<Note>` in document order,
    /// excluding names already owned by the note-parenthesis compatibility
    /// decoder. `XMLTreeNode.all` does not include nested symbols.
    static func decodeAll(
        inNote node: XMLTreeNode,
        excludingNames: Set<String>,
    ) -> [EngravingSymbol] {
        node.all("Symbol")
            .filter { !excludingNames.contains($0.first("name")?.text ?? "") }
            .map(decode)
    }

    /// Decode one `<Symbol>` without throwing. A missing or empty `<name>` is
    /// malformed embellishment, so the unnamed value survives and a diagnostic
    /// records the degradation rather than failing the score.
    /// C++: `TRead::read(Symbol*, …)` (`rw/read460/tread.cpp:2364`).
    private static func decode(_ node: XMLTreeNode) -> EngravingSymbol {
        let name = decodeName(node)
        var symbol = EngravingSymbol(
            name: name,
            scoreFont: node.first("font")?.text,
            size: node.first("symbolsSize").flatMap { Double($0.text) },
            angle: node.first("symbolAngle").flatMap { Double($0.text) },
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        symbol.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return symbol
    }

    private static func decodeName(_ node: XMLTreeNode) -> String {
        guard let name = node.first("name")?.text, !name.isEmpty else {
            mscxDecoderWarn(
                code: "mscx.engravingSymbol.missingName",
                message: "<Symbol> without <name> — kept as an unnamed symbol",
                location: "Note/Symbol",
            )
            return ""
        }
        return name
    }
}
