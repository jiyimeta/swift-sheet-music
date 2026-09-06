import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension EngravingSymbol {
    /// Build the `<Symbol>` element. Inverse of
    /// `MSCXDecoder+EngravingSymbol`.
    ///
    /// Child order follows `TWrite::write(const Symbol*, …)`
    /// (`rw/write/twrite.cpp:3221`): the unconditional `<name>`, the score-font
    /// properties, then `TWrite::writeProperties(const BSymbol*, …)`
    /// (`twrite.cpp:1930`) — which writes the **leaf children first and the
    /// base element properties after them**. That is the opposite of
    /// `ChordBracket`, whose `Arpeggio` base writes item properties first
    /// (`twrite.cpp:764`), so the two encoders in this package deliberately
    /// order their tails differently. Preserved markup is where the leaves —
    /// nested `<Symbol>`, `<Image>`, `<FSymbol>` — live, so it goes out before
    /// `mscxChildren()`.
    ///
    /// `<offset>` now arrives through the shared `mscxChildren()` tail. That
    /// places it after preserved leaf children, matching
    /// `TWrite::writeProperties(const BSymbol*)` (`twrite.cpp:1930`), which
    /// writes leaf children before base item properties. `<color>` follows in
    /// the shared trailing tail, preserving that same leaf-before-base order
    /// while also protecting color from a preserved `<style>` reset.
    ///
    /// Unlike MuseScore's writer, `<symbolsSize>` and `<symbolAngle>` are
    /// emitted whenever present rather than gated on `scoreFont`: `nil` already
    /// records that a tag was absent, and gating would silently drop a value
    /// the source file carried. Upstream ignores both in layout and draw when
    /// no score font resolved (`rendering/score/tdraw.cpp:2980`), so a file
    /// MuseScore wrote reads back identically either way.
    ///
    /// `<name>` is unconditional, matching `twrite.cpp:3224`. An empty `name`
    /// therefore writes `<name></name>`, which upstream resolves to `noSym`
    /// (`types/symnames.cpp:50`) — whereas a `<Symbol>` with **no** `<name>` at
    /// all keeps the constructor default `accidentalSharp`
    /// (`dom/symbol.cpp:49`). This decoder collapses both to an empty name, so
    /// a hand-written `<Symbol/>` comes back as `noSym` rather than a sharp.
    /// MuseScore's own writer never emits the tagless shape.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children = [XMLTreeNode(name: "name", text: name)]
        if let scoreFont {
            children.append(XMLTreeNode(name: "font", text: scoreFont))
        }
        if let size {
            children.append(XMLTreeNode(name: "symbolsSize", text: formatDouble(size)))
        }
        if let angle {
            children.append(XMLTreeNode(name: "symbolAngle", text: formatDouble(angle)))
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxChildren()
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Symbol", children: children)
    }
}
