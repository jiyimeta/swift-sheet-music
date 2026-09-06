import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ExpressionText {
    /// Build the `<Expression>` element. Inverse of `MSCXDecoder+ExpressionText`.
    ///
    /// `snapToDynamics` leads when present because MuseScore's
    /// `TWrite::writeProperties(const TextBase*, ...)` writes styled properties
    /// before `<text>` (`rw/write/twrite.cpp:1353`). What follows is not free
    /// either — see `MSCXEncoder+Sticking.swift` for why `<style>` acts as a
    /// reset and what that constrains for anything added here later.
    ///
    /// `<Expression>` is a MuseScore **4.1**-and-later element. 4.0 and every
    /// 3.x wrote an expression mark as an `expression`-styled `<StaffText>`,
    /// which MuseScore converts on load below MSC 410
    /// (`rw/compat/compatutils.cpp:173`, `CompatUtils::replaceOldWithNewExpressions`).
    /// MuseScore 3.6.2's own reader has no `<Expression>` branch, so a v3-target
    /// encode emits an element it drops as unknown — the same known limitation
    /// `<MeasureRepeat>` has there, 3.6.2 reading only `<RepeatMeasure>`.
    ///
    /// Down-converting to `<StaffText>` is deliberately not done: re-reading
    /// that would produce a `StaffText`, not an `ExpressionText`, an asymmetry
    /// the preservation gate would report as a false loss.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let snapToDynamics {
            children.append(XMLTreeNode(
                name: "snapToDynamics", text: snapToDynamics ? "1" : "0",
            ))
        }
        children.append(XMLTreeNode(name: "text", text: text))
        children += elementProperties.mscxChildren()
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "Expression", children: children)
    }
}
