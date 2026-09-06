import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension FiguredBass {
    /// Every direct `<FiguredBass>` child this decoder reads.
    ///
    /// `color`, `offset`, `placement`, and `visible` are consumed because
    /// `ElementProperties(decodingMSCXChildrenOf:)` reads all four. TextBase
    /// styling tags are deliberately absent: the item-form writer emits
    /// `<style>`, `<size>`, `<align>`, font tags, and related properties as
    /// direct children, and they must survive in `preservedMarkup`.
    private static let consumedChildren: Set = [
        "onNote", "ticks", "FiguredBassItem", "text",
        "color", "offset", "placement", "visible",
    ]

    /// Decode one `<FiguredBass>` without throwing.
    ///
    /// MuseScore rebuilds normalized text when at least one item is present,
    /// so source `<text>` is authoritative only for the item-free form.
    static func decode(_ node: XMLTreeNode) -> FiguredBass {
        let items = node.all("FiguredBassItem").map(FiguredBassItem.decode(_:))
        var figuredBass = FiguredBass(
            items: items,
            text: items.isEmpty
                ? node.first("text").map(StaffText.plainText(of:)) ?? ""
                : "",
            isOnNote: node.first("onNote").map { $0.text != "0" } ?? true,
            ticks: node.first("ticks").flatMap { Fraction(mscxString: $0.text) },
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        figuredBass.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return figuredBass
    }
}

extension FiguredBassItem {
    /// Every direct `<FiguredBassItem>` child this decoder reads. MuseScore
    /// 4.6's reader has no `<display>`, `<displayText>`, or normalized-text
    /// branch; such children and ordinary item properties remain preserved.
    private static let consumedChildren: Set = [
        "brackets", "prefix", "digit", "suffix", "continuationLine",
    ]

    /// Decode one item. Integer ordinals are the 4.6 spelling; enum names are
    /// also accepted for forward-compatible hand-authored input.
    static func decode(_ node: XMLTreeNode) -> FiguredBassItem {
        let brackets = node.first("brackets")
        return FiguredBassItem(
            prefix: decodeModifier(node.first("prefix")?.text, location: "prefix"),
            digit: node.first("digit").flatMap { Int($0.text) },
            suffix: decodeModifier(node.first("suffix")?.text, location: "suffix"),
            continuationLine: decodeContinuationLine(
                node.first("continuationLine")?.text,
            ),
            bracket0: decodeParenthesis(brackets?.attributes["b0"], location: "brackets/@b0"),
            bracket1: decodeParenthesis(brackets?.attributes["b1"], location: "brackets/@b1"),
            bracket2: decodeParenthesis(brackets?.attributes["b2"], location: "brackets/@b2"),
            bracket3: decodeParenthesis(brackets?.attributes["b3"], location: "brackets/@b3"),
            bracket4: decodeParenthesis(brackets?.attributes["b4"], location: "brackets/@b4"),
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
    }

    private static func decodeModifier(_ raw: String?, location: String) -> Modifier? {
        guard let raw else { return nil }
        if let ordinal = Int(raw) { return Modifier(mscxOrdinal: ordinal) }
        guard let value = Modifier(mscxName: raw) else {
            warnUnknown(raw, property: location)
            return nil
        }
        return value
    }

    private static func decodeContinuationLine(_ raw: String?) -> ContinuationLine? {
        guard let raw else { return nil }
        if let ordinal = Int(raw) { return ContinuationLine(mscxOrdinal: ordinal) }
        guard let value = ContinuationLine(mscxName: raw) else {
            warnUnknown(raw, property: "continuationLine")
            return nil
        }
        return value
    }

    private static func decodeParenthesis(_ raw: String?, location: String) -> Parenthesis {
        guard let raw else { return .none }
        if let ordinal = Int(raw) { return Parenthesis(mscxOrdinal: ordinal) }
        guard let value = Parenthesis(mscxName: raw) else {
            warnUnknown(raw, property: location)
            return .none
        }
        return value
    }

    private static func warnUnknown(_ raw: String, property: String) {
        mscxDecoderWarn(
            code: "mscx.figuredBass.unsupportedItemValue",
            message: "Unknown figured-bass item value '\(raw)' — using the default",
            location: "FiguredBass/FiguredBassItem/\(property)",
        )
    }
}
