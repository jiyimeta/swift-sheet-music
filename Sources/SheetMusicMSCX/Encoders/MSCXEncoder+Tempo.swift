import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Tempo {
    /// Build a `<Tempo>` element. Inverse of `Tempo.decode(_:)`: emits `<tempo>` (beats-per-second), then
    /// `<followText>1</followText>` and — last, where MuseScore writes it — the engraved marking as `<text>`,
    /// both only when there is a marking to print; an `<offset x= y=>` element when either coordinate is
    /// non-zero; `<visible>0</visible>` when hidden; and any per-element `TextProperties` overrides.
    ///
    /// The marking is synthesized on every encode because the model keeps no text (`Tempo` has bps, a beat and
    /// dots, nothing else) and MuseScore 4 shows a `TempoText` only through its text — a `<Tempo>` with `<tempo>`
    /// alone opens as an empty, invisible marking. `followText` is what lets `Tempo.decode` read the beat back
    /// out of the printed number, which is what makes encode → decode → encode a fixed point.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "tempo", text: formatDouble(beatsPerSecond)),
        ]
        let marking = markingText
        if marking != nil {
            children.append(XMLTreeNode(name: "followText", text: "1"))
        }
        if offsetX != 0 || offsetY != 0 {
            children.append(XMLTreeNode(
                name: "offset",
                attributes: [
                    "x": formatDouble(offsetX),
                    "y": formatDouble(offsetY),
                ],
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        if let marking {
            children.append(marking)
        }
        return XMLTreeNode(name: "Tempo", children: children)
    }

    /// The engraved marking, in the `<sym>` markup MuseScore's own palette writes (`tempotext.cpp:176-197`):
    /// the beat glyph, then for a dotted beat one `space` and one `metAugmentationDot` per dot, then the number.
    /// The number rides in a `<b>`, which is NOT what MuseScore 4's writer emits: MS4 writes the number as plain
    /// character data trailing the `<sym>` (`<sym>metNoteQuarterUp</sym> = 135`), and `XMLTreeSerializer` cannot
    /// represent that — it writes a node's text BEFORE its children, so a trailing run has to be an element.
    /// `<b>` is the closest representable shape: it has MS3-era precedent in MuseScore's own writer
    /// (`Tests/SheetMusicTests/Resources/testVoltaTemp.mscx:189`, `<b><font face="FreeSerif"/> = 180</b>`),
    /// MuseScore's reader keeps inline elements in order while dropping the whitespace between them
    /// (`xmlreader.cpp:212-237`) so it reads back as the same marking, and tempo text is bold anyway.
    ///
    /// Only what `Tempo.decode` can read back is printed: the six bases `matchBeat` snaps to, with 0…2 dots. Any
    /// other beat prints as a plain quarter at `bps × 60`, which is exactly what decoding it would fall back
    /// to. The number is `beatsPerMinute` to two decimals — MuseScore stores bps to six digits, so 40 BPM is
    /// `0.666667` and would otherwise print as `40.00002`. `nil` when bps is not a positive finite number.
    var markingText: XMLTreeNode? {
        guard beatsPerSecond > 0, beatsPerSecond.isFinite else { return nil }
        let glyph: String
        let dots: Int
        let bpm: Double
        if let known = Self.metronomeGlyph(for: beatNote), (0 ... 2).contains(beatDots) {
            glyph = known
            dots = beatDots
            bpm = beatsPerMinute
        } else {
            glyph = "metNoteQuarterUp"
            dots = 0
            bpm = beatsPerSecond * 60
        }
        var children = [XMLTreeNode(name: "sym", text: glyph)]
        if dots > 0 {
            children.append(XMLTreeNode(name: "sym", text: "space"))
            for _ in 0 ..< dots {
                children.append(XMLTreeNode(name: "sym", text: "metAugmentationDot"))
            }
        }
        let printed = (bpm * 100).rounded() / 100
        children.append(XMLTreeNode(name: "b", text: " = \(formatDouble(printed))"))
        return XMLTreeNode(name: "text", children: children)
    }

    /// SMuFL name of the metronome glyph for `beat` — the `tpSym` names — or `nil` for a beat the decoder's
    /// `matchBeat` would not recognize on the way back.
    static func metronomeGlyph(for beat: NoteDuration) -> String? {
        switch beat {
        case .whole: "metNoteWhole"
        case .half: "metNoteHalfUp"
        case .quarter: "metNoteQuarterUp"
        case .eighth: "metNote8thUp"
        case .sixteenth: "metNote16thUp"
        case .thirtySecond: "metNote32ndUp"
        default: nil
        }
    }
}
