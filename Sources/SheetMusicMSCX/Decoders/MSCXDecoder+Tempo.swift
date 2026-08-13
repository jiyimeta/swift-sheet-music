import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Tempo {
    static func decode(_ node: XMLTreeNode) throws -> Tempo {
        let bps = Double(node.first("tempo")?.text ?? "2") ?? 2.0
        let offset = node.first("offset").map { offsetNode -> (Double, Double) in
            let attrs = offsetNode.attributes
            let x = attrs["x"].flatMap(Double.init) ?? 0
            let y = attrs["y"].flatMap(Double.init) ?? 0
            return (x, y)
        } ?? (0, 0)
        let beat = decodeBeatUnit(node, beatsPerSecond: bps)
        var tempo = Tempo(
            beatsPerSecond: bps,
            offsetX: offset.0,
            offsetY: offset.1,
            properties: TextProperties.decode(node),
            beatNote: beat.note,
            beatDots: beat.dots,
        )
        tempo.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return tempo
    }

    /// Recover the metronome beat unit from the marking. MuseScore stores playback tempo as a quarter-normalized
    /// `<tempo>` (beats/sec) but draws the marking in whatever note the author chose. When `<followText>` is set the
    /// drawn value equals `beatsPerSecond * 60 / (beatLength / quarter)`, so the beat length in quarters is
    /// `beatsPerSecond * 60 / printedValue`. We read the printed number out of `<text>` and snap that ratio to the
    /// nearest standard note (0–2 dots). Falls back to a plain quarter when the text has no number, `followText` is
    /// off, or the ratio matches nothing — the same assumption the engine makes for an unannotated tempo. This mirrors
    /// MuseScore's TempoText math rather than parsing the (version-dependent) note glyph from the text.
    static func decodeBeatUnit(
        _ node: XMLTreeNode, beatsPerSecond: Double,
    ) -> (note: NoteDuration, dots: Int) {
        let fallback: (NoteDuration, Int) = (.quarter, 0)
        guard (node.first("followText")?.text ?? "0") == "1" else { return fallback }
        guard let text = node.first("text").map(plainText(of:)),
              let printed = printedTempoValue(in: text),
              printed > 0,
              beatsPerSecond > 0
        else { return fallback }
        let quartersPerBeat = beatsPerSecond * 60 / printed
        return matchBeat(quartersPerBeat: quartersPerBeat) ?? fallback
    }

    /// Concatenate the text content of `node` and its descendants. MuseScore wraps the marking in inline formatting
    /// tags (`<b>`, `<font>`) so the printed value lands on a nested node — the same shape `StaffText` handles.
    private static func plainText(of node: XMLTreeNode) -> String {
        var result = node.text
        for child in node.children {
            result += plainText(of: child)
        }
        return result
    }

    /// The metronome number printed in a tempo marking — the 80 in "♩. = 80". Reads the first number after the last
    /// `=` (so a leading "Allegro 1:" or the note glyph don't get picked up); if there's no `=`, the first number in
    /// the whole string.
    private static func printedTempoValue(in text: String) -> Double? {
        let scope: String = if let equals = text.range(of: "=", options: .backwards) {
            String(text[equals.upperBound...])
        } else {
            text
        }
        var digits = ""
        for ch in scope {
            if ch.isNumber || (ch == "." && !digits.isEmpty) {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }

    /// Snap a beat length (in quarter notes) to the nearest standard note value carrying 0–2 augmentation dots.
    /// Returns nil when nothing lands within tolerance.
    private static func matchBeat(
        quartersPerBeat target: Double,
    ) -> (note: NoteDuration, dots: Int)? {
        let bases: [NoteDuration] = [.whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond]
        var best: (note: NoteDuration, dots: Int, error: Double)?
        for base in bases {
            for dots in 0 ... 2 {
                let beat = base.dotted(dots).asFraction
                let lengthInQuarters = (Double(beat.numerator) / Double(beat.denominator)) / 0.25
                let error = abs(lengthInQuarters - target)
                guard error < 0.01 else { continue }
                if error < (best?.error ?? .greatestFiniteMagnitude) {
                    best = (base, dots, error)
                }
            }
        }
        return best.map { ($0.note, $0.dots) }
    }
}
