import SheetMusicFoundation
import SheetMusicXMLTools

/// A `<metronome>` as MuseScore reads it (`MusicXmlParserDirection::metronome`, `importmusicxmlpass2.cpp`,
/// `P2:5609-5674`): the text it writes into the tempo marking and the quarter-note tempo it implies.
enum MusicXMLMetronome {
    struct Parsed: Sendable, Equatable {
        /// MuseScore xml text: the beat as `<sym>` glyphs, " = ", then the per-minute value or the second beat.
        var xmlText: String
        /// Quarter notes per minute; 0 unless there is one beat and a numeric `<per-minute>`.
        var quarterBeatsPerMinute: Double
    }

    /// A `<beat-unit>` MuseScore knows (`TConv::fromXml` over `DURATION_TYPES`), dotted by a `<beat-unit-dot>`.
    private struct Beat {
        let kind: BeatKind
        var dotted = false
    }

    /// A note value: its length as a fraction of a whole note and its glyph in `TempoText`'s `tpSym` table
    /// (`tempotext.cpp:170-198`) — `nil` when the table has none — and whether the table lists it dotted.
    private struct BeatKind {
        let numerator: Int
        let denominator: Int
        let glyph: String?
        let dottable: Bool
    }

    static func parse(_ node: XMLTreeNode) -> Parsed {
        var first: Beat?
        var second: Beat?
        var perMinute = ""
        for child in node.children {
            switch child.name {
            case "beat-unit":
                // The first beat still unset takes it; a name MuseScore does not know leaves that slot unset, so the
                // next `<beat-unit>` fills it.
                let beat = kinds[child.text].map { Beat(kind: $0) }
                if first == nil { first = beat } else if second == nil { second = beat }
            case "beat-unit-dot":
                // MuseScore sets the dots of the last set beat to 1 (`setDots(1)`, `P2:5637-5642`), so two
                // `<beat-unit-dot/>` still make one dot.
                if second != nil { second?.dotted = true } else { first?.dotted = true }
            case "per-minute":
                perMinute = child.text
            default:
                // `<metronome-note>`, `<metronome-relation>` and the rest are skipped.
                break
            }
        }
        var text = beatsText(first: first, second: second, perMinute: perMinute)
        if node.attributes["parentheses"] == "yes" { text = "(" + text + ")" }
        return Parsed(
            xmlText: text,
            quarterBeatsPerMinute: quarterBeatsPerMinute(first: first, second: second, perMinute: perMinute),
        )
    }

    /// The first beat's glyphs, then " = " and the second beat's glyphs or the per-minute text.
    private static func beatsText(first: Beat?, second: Beat?, perMinute: String) -> String {
        var text = ""
        if let first { text += symbols(first) }
        if let second {
            text += " = " + symbols(second)
        } else if !perMinute.isEmpty {
            text += " = " + perMinute
        }
        return text
    }

    /// `4 × perMinute × beat length`, only with one beat and a numeric `<per-minute>` (`P2:5660-5667`).
    private static func quarterBeatsPerMinute(first: Beat?, second: Beat?, perMinute: String) -> Double {
        guard let first, second == nil, let value = Double(perMinute) else { return 0 }
        var numerator = first.kind.numerator
        var denominator = first.kind.denominator
        if first.dotted {
            numerator *= 3
            denominator *= 2
        }
        return 4 * Double(numerator) * value / Double(denominator)
    }

    /// `TempoText::duration2tempoTextString` (`tempotext.cpp:206-215`): the beat's `tpSym` pattern, or "" for a beat
    /// the table does not list.
    private static func symbols(_ beat: Beat) -> String {
        guard let glyph = beat.kind.glyph else { return "" }
        guard beat.dotted else { return "<sym>\(glyph)</sym>" }
        return beat.kind.dottable ? "<sym>\(glyph)</sym><sym>space</sym><sym>metAugmentationDot</sym>" : ""
    }

    /// `DURATION_TYPES`' xml names (`typesconv.cpp:2130-2147`) but `measure`, whose length is not a note value.
    private static let kinds: [String: BeatKind] = [
        "long": BeatKind(numerator: 4, denominator: 1, glyph: nil, dottable: false),
        "breve": BeatKind(numerator: 2, denominator: 1, glyph: "metNoteDoubleWholeSquare", dottable: false),
        "whole": BeatKind(numerator: 1, denominator: 1, glyph: "metNoteWhole", dottable: true),
        "half": BeatKind(numerator: 1, denominator: 2, glyph: "metNoteHalfUp", dottable: true),
        "quarter": BeatKind(numerator: 1, denominator: 4, glyph: "metNoteQuarterUp", dottable: true),
        "eighth": BeatKind(numerator: 1, denominator: 8, glyph: "metNote8thUp", dottable: true),
        "16th": BeatKind(numerator: 1, denominator: 16, glyph: "metNote16thUp", dottable: true),
        "32nd": BeatKind(numerator: 1, denominator: 32, glyph: "metNote32ndUp", dottable: true),
        "64th": BeatKind(numerator: 1, denominator: 64, glyph: "metNote64thUp", dottable: false),
        "128th": BeatKind(numerator: 1, denominator: 128, glyph: "metNote128thUp", dottable: false),
        "256th": BeatKind(numerator: 1, denominator: 256, glyph: "metNote256thUp", dottable: false),
        "512th": BeatKind(numerator: 1, denominator: 512, glyph: "metNote512thUp", dottable: false),
        "1024th": BeatKind(numerator: 1, denominator: 1024, glyph: "metNote1024thUp", dottable: false),
    ]
}
