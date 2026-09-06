import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension FiguredBass {
    /// Build the `<FiguredBass>` element. Inverse of
    /// `MSCXDecoder+FiguredBass`.
    ///
    /// Child order follows `TWrite::write(const FiguredBass*, ...)`
    /// (`rw/write/twrite.cpp:1279`): non-default placement and duration first,
    /// then exactly one payload representation. Parsed items win over `text`,
    /// matching MuseScore's own writer and its derived-text reader behavior.
    /// `<FiguredBass>` predates every supported target, so no version branch is
    /// needed.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if !isOnNote {
            children.append(XMLTreeNode(name: "onNote", text: "0"))
        }
        if let ticks {
            children.append(XMLTreeNode(
                name: "ticks",
                text: "\(ticks.numerator)/\(ticks.denominator)",
            ))
        }
        if items.isEmpty {
            children.append(XMLTreeNode(name: "text", text: text))
        } else {
            children += items.map { $0.encode(options: options) }
        }
        children += elementProperties.mscxChildren()
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "FiguredBass", children: children)
    }
}

extension FiguredBassItem {
    /// Build one `<FiguredBassItem>` in MuseScore 4.6's ordinal form.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children = [XMLTreeNode(
            name: "brackets",
            attributes: [
                "b0": String(bracket0.mscxOrdinal),
                "b1": String(bracket1.mscxOrdinal),
                "b2": String(bracket2.mscxOrdinal),
                "b3": String(bracket3.mscxOrdinal),
                "b4": String(bracket4.mscxOrdinal),
            ],
        )]
        if let prefix, prefix != .none {
            children.append(XMLTreeNode(name: "prefix", text: String(prefix.mscxOrdinal)))
        }
        if let digit {
            children.append(XMLTreeNode(name: "digit", text: String(digit)))
        }
        if let suffix, suffix != .none {
            children.append(XMLTreeNode(name: "suffix", text: String(suffix.mscxOrdinal)))
        }
        if let continuationLine, continuationLine != .none {
            children.append(XMLTreeNode(
                name: "continuationLine",
                text: String(continuationLine.mscxOrdinal),
            ))
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "FiguredBassItem", children: children)
    }
}
