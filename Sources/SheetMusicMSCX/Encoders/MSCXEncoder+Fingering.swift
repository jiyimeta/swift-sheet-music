import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Fingering {
    /// Build the `<Fingering>` element. Inverse of `MSCXDecoder+Fingering`.
    ///
    /// `<style>` leads and is omitted for `.fingering`, because that is
    /// MuseScore's default text style for the element and `writeProperty`
    /// skips a property equal to its default — so a plain finger number comes
    /// back out as the bare `<Fingering><text>1</text></Fingering>` it was
    /// read as. Child order otherwise follows `TWrite::writeProperties(const
    /// TextBase*, …)` (`rw/write/twrite.cpp:1353`), which writes the style
    /// before the text.
    ///
    /// Both MuseScore 3 and 4 read this shape, so there is no version branch.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let style = role.mscxToken {
            children.append(XMLTreeNode(name: "style", text: style))
        }
        children.append(XMLTreeNode(name: "text", text: text))
        children += elementProperties.mscxChildren()
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Fingering", children: children)
    }
}
