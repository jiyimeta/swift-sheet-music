import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Lyric {
    /// Build the `<Lyrics>` element attached to a Chord. Mirrors the
    /// inverse of `MSCXDecoder+Chord` lyric reading: emits `<no>` for
    /// non-zero verse, `<syllabic>` for non-default placement,
    /// the melisma (`melismaNode(options:)`), optional `<linkedMain/>` (v3 only —
    /// MuseScore 3 marks every score-graph element with this flag),
    /// per-element font/frame overrides via `TextProperties.appendXML`, then
    /// the syllable's `<text>` payload after the metadata children (as the MS3
    /// reader expects). Preserved markup and the universal trailing `<color>`
    /// follow it.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if verse != 0 {
            children.append(XMLTreeNode(name: "no", text: String(verse)))
        }
        if syllabic != .single {
            children.append(XMLTreeNode(
                name: "syllabic", text: syllabicMSCXName,
            ))
        }
        if ticks > 0 {
            children.append(melismaNode(options: options))
        }
        if options.targetVersion == .v3 {
            children.append(XMLTreeNode(name: "linkedMain"))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        children.append(encodeText(
            text,
            preservedTextMarkup: preservedTextMarkup,
            options: options,
        ))
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Lyrics", children: children)
    }

    /// Whether `encode(options:)` writes this syllable's preserved markup back: it is on, and the markup still
    /// describes `text` (`encodeText`'s own condition). A syllable of symbols alone is saved on this account alone, its
    /// text being empty — the glissando label's encoder keeps a symbol-only label the same way.
    func savesMarkup(options: MSCXEncoderOptions) -> Bool {
        options.emitPreservedMarkup && preservedTextMarkup?.derivedText == text
    }

    /// The melisma's length in the form the target reads. MuseScore 4 writes `<ticks_f>`, a fraction of a whole note,
    /// and from 4.6 on reads nothing else — a `<ticks>` in a 4.60 file is skipped as unknown
    /// (`read460::TRead::readProperties(Lyrics*)`). MuseScore 3 reads the integer `<ticks>`.
    private func melismaNode(options: MSCXEncoderOptions) -> XMLTreeNode {
        switch options.targetVersion {
        case .v2, .v3:
            return XMLTreeNode(name: "ticks", text: String(ticks))
        case .v4:
            let length = Fraction(numerator: ticks, denominator: 4 * options.division)
            return XMLTreeNode(name: "ticks_f", text: "\(length.numerator)/\(length.denominator)")
        }
    }

    private var syllabicMSCXName: String {
        switch syllabic {
        case .single: "single"
        case .begin: "begin"
        case .middle: "middle"
        case .end: "end"
        }
    }
}
