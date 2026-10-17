import SheetMusicFoundation

/// What MuseScore makes of a metronome written as `<words>` (`MusicXmlParserDirection::handleTempo`,
/// `importmusicxmlpass2.cpp`, `P2:4904-4977`): Sibelius draws "q. = c. 78" in a symbol font whose letters are note
/// values, and the MetTimes font draws them as `Œ` and `Ó`.
struct MusicXMLMetronomeWords: Sendable, Equatable {
    /// The words' new xml text: their plain text with the beat letter as its `<sym>` glyphs — the formatting is lost,
    /// as MuseScore replaces it in the plain text (`P2:4945-4964`).
    let xmlText: String
    /// MuseScore's `m_tpoMetro`: `4 × number × the beat's length`, in quarter notes per minute (`P2:4966-4975`);
    /// `nil` when the number does not read.
    let quarterBeatsPerMinute: Double?
}

extension MusicXMLDirectionDecoder {
    /// A beat letter's note value: its glyph and its length as a fraction of a whole note.
    private struct MetronomeWordsBeat {
        let glyph: String
        let numerator: Int
        let denominator: Int
    }

    /// `sibeliusSyms` (`P2:4911-4920`).
    private static let sibeliusBeats: [Character: MetronomeWordsBeat] = [
        "y": MetronomeWordsBeat(glyph: "metNote32ndUp", numerator: 1, denominator: 32),
        "x": MetronomeWordsBeat(glyph: "metNote16thUp", numerator: 1, denominator: 16),
        "e": MetronomeWordsBeat(glyph: "metNote8thUp", numerator: 1, denominator: 8),
        "q": MetronomeWordsBeat(glyph: "metNoteQuarterUp", numerator: 1, denominator: 4),
        "h": MetronomeWordsBeat(glyph: "metNoteHalfUp", numerator: 1, denominator: 2),
        "w": MetronomeWordsBeat(glyph: "metNoteWhole", numerator: 1, denominator: 1),
        "V": MetronomeWordsBeat(glyph: "metNoteDoubleWholeSquare", numerator: 2, denominator: 1),
        "W": MetronomeWordsBeat(glyph: "metNoteDoubleWhole", numerator: 2, denominator: 1),
    ]

    /// `metTimesSyms` (`P2:4922-4925`).
    private static let metTimesBeats: [Character: MetronomeWordsBeat] = [
        "Œ": MetronomeWordsBeat(glyph: "metNoteQuarterUp", numerator: 1, denominator: 4),
        "Ó": MetronomeWordsBeat(glyph: "metNoteHalfUp", numerator: 1, denominator: 2),
    ]

    /// One `<words>` read as a metronome, when inferring: the Sibelius letters in a Sibelius or Dolet file, else the
    /// MetTimes letters in words set in "MetTimes Plain" (`P2:4927-4935`). `plain` is the words' simplified plain text.
    /// The beat is the LAST letter followed by an optional `.`, optional whitespace (or no-break space), `=`, any
    /// non-digits and a digit, as MuseScore's pattern reads it, whose leading `.*` is greedy (`P2:4947`); the number
    /// is the run of digits there. `nil` when the words are no metronome.
    static func metronomeWords(
        plain: String, software: MusicXMLExporterSoftware, fontFamily: String?,
    ) -> MusicXMLMetronomeWords? {
        let beats: [Character: MetronomeWordsBeat]
        if software.isSibeliusOrDolet {
            beats = sibeliusBeats
        } else if fontFamily == "MetTimes Plain" {
            beats = metTimesBeats
        } else {
            return nil
        }
        let characters = Array(plain)
        guard let match = lastMetronomeMatch(in: characters, beats: beats), let beat = beats[characters[match.letter]]
        else { return nil }
        let rest = match.letter + (match.dotted ? 2 : 1)
        let dot = match.dotted ? "<sym>space</sym><sym>metAugmentationDot</sym>" : ""
        let xmlText = escapedPlain(characters[..<match.letter]) + "<sym>\(beat.glyph)</sym>" + dot
            + escapedPlain(characters[rest...])
        var numerator = beat.numerator
        var denominator = beat.denominator
        if match.dotted {
            numerator *= 3
            denominator *= 2
        }
        let bpm = Double(match.digits).map { 4 * Double(numerator) * $0 / Double(denominator) }
        return MusicXMLMetronomeWords(xmlText: xmlText, quarterBeatsPerMinute: bpm)
    }

    /// The last letter position the pattern matches at, whether a dot follows it, and the number's digits.
    private static func lastMetronomeMatch(
        in characters: [Character], beats: [Character: MetronomeWordsBeat],
    ) -> (letter: Int, dotted: Bool, digits: String)? {
        var index = characters.count - 1
        while index >= 0 {
            if beats[characters[index]] != nil, let found = metronomeTail(in: characters, after: index) {
                return (index, found.dotted, found.digits)
            }
            index -= 1
        }
        return nil
    }

    /// The pattern's tail from just after the letter at `letter`: an optional dot, whitespace, `=`, non-digits, then
    /// the digits.
    private static func metronomeTail(
        in characters: [Character], after letter: Int,
    ) -> (dotted: Bool, digits: String)? {
        var index = letter + 1
        let dotted = index < characters.count && characters[index] == "."
        if dotted { index += 1 }
        while index < characters.count, isMetronomeSpace(characters[index]) {
            index += 1
        }
        guard index < characters.count, characters[index] == "=" else { return nil }
        index += 1
        while index < characters.count, !isASCIIDigit(characters[index]) {
            index += 1
        }
        var digits = ""
        while index < characters.count, isASCIIDigit(characters[index]) {
            digits.append(characters[index])
            index += 1
        }
        return digits.isEmpty ? nil : (dotted, digits)
    }

    private static func isMetronomeSpace(_ character: Character) -> Bool {
        [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}", "\u{A0}"].contains(character)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isWholeNumber
    }

    /// Plain text as xml text: `&`, `<` and `>` as entities, so the text reads back as the same characters.
    private static func escapedPlain(_ characters: ArraySlice<Character>) -> String {
        var result = ""
        for character in characters {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }
}
