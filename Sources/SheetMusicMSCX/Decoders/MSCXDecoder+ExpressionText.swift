import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ExpressionText {
    /// Every direct `<Expression>` child this decoder reads. `<style>`,
    /// `<placement>`, font overrides, and voice-assignment properties are not
    /// modeled and become preserved markup. The base `<offset>` is owned by
    /// `ElementProperties`.
    ///
    /// `color` and `visible` are consumed because
    /// `ElementProperties(decodingMSCXChildrenOf:)` reads them.
    private static let consumedChildren: Set = [
        "text", "snapToDynamics", "color", "offset", "visible",
    ]

    /// Decode one `<Expression>`.
    ///
    /// Nothing throws: an expression is an embellishment under the parser
    /// policy, and an empty one degrades to empty text rather than failing the
    /// score. C++: `TRead::read(Expression*, ...)` handles
    /// `<snapToDynamics>` and delegates the rest to `TRead::read(TextBase*)`
    /// (`rw/read460/tread.cpp:804`).
    static func decode(_ node: XMLTreeNode) -> ExpressionText {
        var expression = ExpressionText(
            text: node.first("text").map(StaffText.plainText(of:)) ?? "",
            snapToDynamics: node.first("snapToDynamics").map { $0.text != "0" },
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        expression.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return expression
    }
}
