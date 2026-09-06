import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ExpressionText {
    /// Every direct `<Expression>` child this decoder reads. `<style>`, font
    /// overrides, and voice-assignment properties are not modeled and become
    /// preserved markup. The base `<offset>` and `<placement>` are owned by
    /// `ElementProperties`.
    ///
    /// `color` and `visible` are consumed because
    /// `ElementProperties(decodingMSCXChildrenOf:)` reads them.
    private static let consumedChildren: Set = [
        "text", "snapToDynamics", "color", "offset", "placement", "visible",
    ]

    /// Decode one `<Expression>`.
    ///
    /// Nothing throws: an expression is an embellishment under the parser
    /// policy, and an empty one degrades to empty text rather than failing the
    /// score. C++: `TRead::read(Expression*, ...)` handles
    /// `<snapToDynamics>` and delegates the rest to `TRead::read(TextBase*)`
    /// (`rw/read460/tread.cpp:804`).
    static func decode(_ node: XMLTreeNode) -> ExpressionText {
        let textNode = node.first("text")
        var expression = ExpressionText(
            text: textNode.map(StaffText.plainText(of:)) ?? "",
            snapToDynamics: node.first("snapToDynamics").map { $0.text != "0" },
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
            preservedTextMarkup: textNode.flatMap(StaffText.preservedTextMarkup(of:)),
        )
        expression.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return expression
    }
}
