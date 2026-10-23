import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension TupletAppearance {
    /// Every direct `<Tuplet>` child read here or by the voice decoder. Anything else becomes preserved markup.
    ///
    /// - `normalNotes`, `actualNotes` — the voice decoder reads them into `Tuplet` itself.
    /// - `baseNote`, `baseDots` — the unit, which the encoder works out again from the members
    ///   (`Voice.tupletBaseDuration`).
    /// - `Number` — the number MuseScore makes again on every layout from the ratio and `numberType`
    ///   (`TupletLayout::createNumber` sets its text); MuseScore writes only its `<style>` and `<text>`. Dropped rather
    ///   than preserved: MuseScore 4 names the style `tuplet`, which MuseScore 3 does not know (`textStyleFromName`
    ///   falls back to the default style), so carrying it into a 3.x file would restyle the number there.
    /// - `track` — MuseScore 3's track number, which follows from the voice the tuplet is written in.
    /// - `visible`, `color`, `offset`, `placement`, `autoplace` — `ElementProperties(decodingMSCXChildrenOf:)`.
    static let consumedChildren: Set = [
        "normalNotes", "actualNotes", "baseNote", "baseDots", "Number", "track",
        "direction", "numberType", "bracketType",
        "visible", "color", "offset", "placement", "autoplace",
    ]

    /// Decode a `<Tuplet>` element's display settings. An unknown value is reported and left unset, so the tuplet
    /// follows the style as if the tag were absent. C++: `TRead::read(Tuplet*, ...)` (`rw/read460/tread.cpp`).
    static func decodeMSCX(_ node: XMLTreeNode) -> TupletAppearance {
        TupletAppearance(
            direction: decoded(node, "direction", code: "mscx.tuplet.unknownDirection", as: Direction.init(mscxText:)),
            numberType: decoded(node, "numberType", code: "mscx.tuplet.unknownNumberType") {
                Int($0).flatMap(NumberType.init(rawValue:))
            },
            bracketType: decoded(node, "bracketType", code: "mscx.tuplet.unknownBracketType") {
                Int($0).flatMap(BracketType.init(rawValue:))
            },
            elementProperties: ElementProperties(decodingMSCXChildrenOf: node),
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
    }

    private static func decoded<Value>(
        _ node: XMLTreeNode, _ tag: String, code: String, as parse: (String) -> Value?,
    ) -> Value? {
        guard let child = node.first(tag) else { return nil }
        if let value = parse(child.text) { return value }
        mscxDecoderWarn(
            code: code,
            message: "Unknown <Tuplet><\(tag)> '\(child.text)'; following the style",
            location: "Tuplet/\(tag)",
        )
        return nil
    }
}

extension TupletAppearance.Direction {
    /// MuseScore 4 writes `auto` / `up` / `down` (`TConv::toXml(DirectionV)`); the ordinal form (0 / 1 / 2) is what the
    /// `<Style>` block uses, accepted here too.
    init?(mscxText text: String) {
        switch text {
        case "auto", "0": self = .auto
        case "up", "1": self = .up
        case "down", "2": self = .down
        default: return nil
        }
    }

    var mscxText: String {
        switch self {
        case .auto: "auto"
        case .up: "up"
        case .down: "down"
        }
    }
}
