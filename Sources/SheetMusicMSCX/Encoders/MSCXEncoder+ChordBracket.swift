import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ChordBracket {
    /// Build the `<ChordBracket>` element. Inverse of
    /// `MSCXDecoder+ChordBracket`.
    ///
    /// Child order follows `TWrite::write(const ChordBracket*, …)`
    /// (`rw/write/twrite.cpp:747`): bracket-specific properties, inherited
    /// element properties, then the unmodeled `Arpeggio` properties restored
    /// from preserved markup. The shared writer never emits `<subtype>` for a
    /// chord bracket.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let hookLength {
            children.append(XMLTreeNode(
                name: "bracketHookLen", text: formatDouble(hookLength),
            ))
        }
        if let hookPosition {
            children.append(XMLTreeNode(
                name: "bracketHookPos", text: hookPosition.rawValue,
            ))
        }
        if let isRightSide {
            children.append(XMLTreeNode(
                name: "bracketRightSide", text: isRightSide ? "1" : "0",
            ))
        }
        children += elementProperties.mscxChildren()
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "ChordBracket", children: children)
    }
}
