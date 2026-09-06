import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Sticking {
    /// Every direct `<Sticking>` child this decoder reads. `<style>`,
    /// `<placement>`, `<offset>`, and font overrides are not modeled and
    /// become preserved markup.
    ///
    /// `color` and `visible` are consumed because
    /// `ElementProperties(decodingMSCXChildrenOf:)` reads them.
    private static let consumedChildren: Set = [
        "text", "color", "visible",
    ]

    /// Decode one `<Sticking>`.
    ///
    /// Nothing throws: a sticking is an embellishment under the parser policy,
    /// and an empty one degrades to empty text rather than failing the score.
    /// C++: `TRead::read(Sticking*, ...)` delegates to `TRead::read(TextBase*)`
    /// (`rw/read460/tread.cpp:906`).
    static func decode(_ node: XMLTreeNode) -> Sticking {
        var sticking = Sticking(
            text: node.first("text").map(StaffText.plainText(of:)) ?? "",
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        sticking.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return sticking
    }
}
