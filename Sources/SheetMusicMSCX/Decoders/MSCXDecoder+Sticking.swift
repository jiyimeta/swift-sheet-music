import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Sticking {
    /// Every direct `<Sticking>` child this decoder reads. `<style>` and font
    /// overrides are not modeled and become preserved markup. The base
    /// `<offset>` and `<placement>` are owned by `ElementProperties`.
    ///
    /// `color` and `visible` are consumed because
    /// `ElementProperties(decodingMSCXChildrenOf:)` reads them.
    private static let consumedChildren: Set = [
        "text", "color", "offset", "placement", "visible",
    ]

    /// Decode one `<Sticking>`.
    ///
    /// Nothing throws: a sticking is an embellishment under the parser policy,
    /// and an empty one degrades to empty text rather than failing the score.
    /// C++: `TRead::read(Sticking*, ...)` delegates to `TRead::read(TextBase*)`
    /// (`rw/read460/tread.cpp:906`).
    static func decode(_ node: XMLTreeNode) -> Sticking {
        let textNode = node.first("text")
        var sticking = Sticking(
            text: textNode.map(StaffText.plainText(of:)) ?? "",
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
            preservedTextMarkup: textNode.flatMap(StaffText.preservedTextMarkup(of:)),
        )
        sticking.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return sticking
    }
}
