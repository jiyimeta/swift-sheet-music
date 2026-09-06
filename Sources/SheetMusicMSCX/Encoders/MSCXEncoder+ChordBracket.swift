import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ChordBracket {
    /// Build the `<ChordBracket>` element. Inverse of
    /// `MSCXDecoder+ChordBracket`.
    ///
    /// Child order follows `TWrite::write(const ChordBracket*, …)`
    /// (`rw/write/twrite.cpp:747`): bracket-specific properties, ordinary
    /// element properties, then the unmodeled `Arpeggio` properties restored
    /// from preserved markup. The trailing `<color>` deliberately follows all
    /// of them; see `ElementProperties.mscxTrailingChildren()`. The shared
    /// writer never emits `<subtype>` for a chord bracket. `<offset>` arrives
    /// through `mscxChildren()`, so its position matches
    /// `TWrite::writeProperties(const Arpeggio*)`
    /// (`rw/write/twrite.cpp:764`), which writes item properties first.
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
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "ChordBracket", children: children)
    }
}
