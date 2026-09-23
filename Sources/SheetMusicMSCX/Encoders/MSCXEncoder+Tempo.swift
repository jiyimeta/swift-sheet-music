import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Tempo {
    /// Build a `<Tempo>` element. Inverse of `Tempo.decode(_:)`: emits `<tempo>` (beats-per-second), then
    /// `<followText>1</followText>` and the engraved marking as `<text>`, both only when there is a marking to
    /// print; a shared `<offset x= y=>` element when present; `<visible>0</visible>` when hidden; any per-element
    /// `TextProperties` overrides; and the shared `<color>` trailing child last.
    ///
    /// The marking is synthesized on every encode because the model keeps no text (`Tempo` has bps, a beat and
    /// dots, nothing else) and MuseScore 4 shows a `TempoText` only through its text — a `<Tempo>` with `<tempo>`
    /// alone opens as an empty, invisible marking. `followText` is what lets `Tempo.decode` read the beat back
    /// out of the printed number, which is what makes encode → decode → encode a fixed point.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "tempo", text: formatDouble(beatsPerSecond)),
        ]
        let marking = markingText
        if marking != nil {
            children.append(XMLTreeNode(name: "followText", text: "1"))
        }
        // `<eid>` sits here: `TWrite::write(const TempoText*, ...)`
        // (`rw/write/twrite.cpp:3163-3181`) writes `PLAY`/`<tempo>`/
        // `<followText>`/`<type>` (this model has no `PLAY` or
        // `<type>` field) before calling `writeProperties(TextBase*,
        // ..., true)`, whose own first act is `writeItemProperties` —
        // the `<eid>` writer — ahead of everything
        // `elementProperties.mscxChildren()` and `<text>` below.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        if let marking {
            children.append(marking)
        }
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Tempo", children: children)
    }

    /// The engraved marking, in the `<sym>` markup MuseScore's own palette writes (`tempotext.cpp:176-197`):
    /// the beat glyph, then for a dotted beat one `space` and one `metAugmentationDot` per dot, then the number as
    /// plain character data trailing the glyphs — `<text><sym>metNoteQuarterUp</sym> = 120</text>`, exactly what
    /// MuseScore 4's writer emits (`TWrite::write(const TempoText*)` → `XmlWriter::writeXml`, one line).
    ///
    /// **Written inline, through `mixedContent`.** It used to be ordinary children, which `XMLTreeSerializer`
    /// pretty-prints one per line, with the number in a `<b>` because the serializer could not then write trailing
    /// character data. MuseScore opened that as a two-line marking — the note on one line, "= 120" on the next —
    /// because the indentation between the tags is character data inside a `<text>` it reads as markup. The inline
    /// path (`XMLTreeSerializer.writeInline`) writes the content with nothing between the items.
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
        var symbols = [XMLTreeNode(name: "sym", text: glyph)]
        if dots > 0 {
            symbols.append(XMLTreeNode(name: "sym", text: "space"))
            for _ in 0 ..< dots {
                symbols.append(XMLTreeNode(name: "sym", text: "metAugmentationDot"))
            }
        }
        let printed = (bpm * 100).rounded() / 100
        let number = " = \(formatDouble(printed))"
        return XMLTreeNode(
            name: "text",
            text: number.trimmingWhitespaceAndNewlines(),
            children: symbols,
            mixedContent: symbols.map(XMLContentItem.element) + [.characters(number)],
        )
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
