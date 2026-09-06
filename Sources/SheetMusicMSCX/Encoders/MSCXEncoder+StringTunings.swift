import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StringTunings {
    /// Build the `<StringTunings>` element. Inverse of
    /// `MSCXDecoder+StringTunings`.
    ///
    /// Child order follows `TWrite::write(const StringTunings*, ...)`
    /// (`rw/write/twrite.cpp:3205`). `<visibleStrings>` is always present and
    /// retains the model's order; `<StringData>` is present only when the
    /// optional modeled value exists.
    ///
    /// `<StringTunings>` is a MuseScore **4.1**-and-later element. A v3-target
    /// encode therefore emits an element MuseScore 3 drops, the same known
    /// limitation as `<Expression>` and `<MeasureRepeat>`; no v3
    /// down-conversion is attempted.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children = [
            XMLTreeNode(name: "preset", text: preset),
            XMLTreeNode(
                name: "visibleStrings",
                text: visibleStrings.map(String.init).joined(separator: ","),
            ),
        ]
        if let stringData {
            children.append(stringData.encode(options: options))
        }
        children.append(encodeText(
            text,
            preservedTextMarkup: preservedTextMarkup,
            options: options,
        ))
        children += elementProperties.mscxChildren()
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "StringTunings", children: children)
    }
}
