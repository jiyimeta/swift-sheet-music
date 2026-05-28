import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Lyric {
    /// Build the `<Lyrics>` element attached to a Chord. Mirrors the
    /// inverse of `MSCXDecoder+Chord` lyric reading: emits `<no>` for
    /// non-zero verse, `<syllabic>` for non-default placement,
    /// `<ticks>` for melismas, optional `<linkedMain/>` (v3 only —
    /// MuseScore 3 marks every score-graph element with this flag),
    /// per-element font/frame overrides via `TextProperties.appendXML`,
    /// then the syllable's `<text>` payload last (MS3 reader expects
    /// text after the metadata children).
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
            children.append(XMLTreeNode(name: "ticks", text: String(ticks)))
        }
        if options.targetVersion == .v3 {
            children.append(XMLTreeNode(name: "linkedMain"))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        children.append(XMLTreeNode(name: "text", text: text))
        return XMLTreeNode(name: "Lyrics", children: children)
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
