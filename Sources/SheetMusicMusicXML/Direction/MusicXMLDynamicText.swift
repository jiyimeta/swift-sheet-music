import SheetMusicFoundation

/// A MusicXML dynamic's text as MuseScore reads it: the subtypes it knows, the split of an `<other-dynamics>` text into
/// a subtype and the dynamic's own words (`Dynamic::parseDynamicText`, `engraving/dom/dynamic.cpp:243-258`), and the
/// words that are a dynamic (`MusicXmlParserDirection::textToDynamic`, `P2:4511-4540`).
enum MusicXMLDynamicText {
    /// MuseScore's dynamic subtypes in `DYN_LIST` order (`engraving/dom/dynamic.cpp:49-101`), spelled as
    /// `TConv::toXml(DynamicType)` spells them; `other-dynamics` (MuseScore's `OTHER`) is not one of them.
    static let subtypes: [String] = [
        "pppppp", "ppppp", "pppp", "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "ffff", "fffff", "ffffff",
        "fp", "pf", "sf", "sfz", "sff", "sffz", "sfff", "sfffz", "sfp", "sfpp", "rfz", "rf", "fz", "m", "r", "s", "z",
        "n",
    ]

    /// MuseScore's `DYN_LIST[i].text`: the subtype spelled letter by letter as SMuFL glyphs; "" for a name that is no
    /// subtype (`OTHER`'s text).
    static func glyphs(_ subtype: String) -> String {
        guard subtypes.contains(subtype) else { return "" }
        return subtype.map { letter -> String in
            switch letter {
            case "p": "<sym>dynamicPiano</sym>"
            case "m": "<sym>dynamicMezzo</sym>"
            case "f": "<sym>dynamicForte</sym>"
            case "r": "<sym>dynamicRinforzando</sym>"
            case "s": "<sym>dynamicSforzando</sym>"
            case "z": "<sym>dynamicZ</sym>"
            case "n": "<sym>dynamicNiente</sym>"
            default: ""
            }
        }.joined()
    }

    /// The first known dynamic token in `tag` and the dynamic's own words in MuseScore xml text — the tag with the
    /// token spelled as its glyphs — or `nil` words when that is just the subtype's glyphs; `("other-dynamics", nil)`
    /// when no token is known. A token is MuseScore's `(?:<sym>.*?</sym>)+|\b[fmnprsz]+\b(?=[^>]|$)`, matched left to
    /// right; `std::regex` runs on UTF-8 bytes, so only ASCII letters, digits and `_` are word characters.
    static func parse(_ tag: String) -> (subtype: String, customXML: String?) {
        let characters = Array(tag)
        var index = 0
        while index < characters.count {
            guard let end = tokenEnd(in: characters, at: index) else {
                index += 1
                continue
            }
            let token = String(characters[index ..< end])
            if let subtype = subtypes.first(where: { $0 == token || glyphs($0) == token }) {
                let spelled = glyphs(subtype)
                let replaced = String(characters[..<index]) + spelled + String(characters[end...])
                return (subtype, replaced == spelled ? nil : replaced)
            }
            index = end
        }
        return ("other-dynamics", nil)
    }

    /// The subtype a `<words>` text is, when inferring (`textToDynamic`): its simplified plain text — after Finale's
    /// letters are read as the dynamics Finale meant (`P2:4519-4528`) — is a subtype, and not a lone `m`, `r`, `s` or
    /// `z` (`P2:4530-4533`).
    static func wordsDynamic(_ xmlText: String, finale: Bool) -> String? {
        var plain = MusicXMLFormattedWords.simplified(MusicXMLFormattedWords.plainText(ofXMLText: xmlText))
        if finale, let substitute = finaleSubstitutes[plain] { plain = substitute }
        guard !["m", "r", "s", "z"].contains(plain), subtypes.contains(plain) else { return nil }
        return plain
    }

    /// `finaleDynamicSubs`, `P2:4521-4524`.
    private static let finaleSubstitutes: [String: String] = [
        "π": "pp", "P": "mp", "F": "mf", "ƒ": "ff", "Ï": "fff", "S": "sf", "ß": "sfz", "Z": "fz", "Í": "fp",
    ]

    /// Where a token starting at `index` ends, or `nil` when none starts there.
    private static func tokenEnd(in characters: [Character], at index: Int) -> Int? {
        if let end = symRunEnd(in: characters, at: index) { return end }
        guard dynamicLetters.contains(characters[index]),
              index == 0 || !isWordCharacter(characters[index - 1])
        else { return nil }
        var end = index
        while end < characters.count, dynamicLetters.contains(characters[end]) {
            end += 1
        }
        guard end == characters.count || (!isWordCharacter(characters[end]) && characters[end] != ">")
        else { return nil }
        return end
    }

    /// `(?:<sym>.*?</sym>)+`: as many `<sym>…</sym>` in a row as there are, each closed by its first `</sym>` on the
    /// same line (`.` matches no line break).
    private static func symRunEnd(in characters: [Character], at index: Int) -> Int? {
        var position = index
        while has(symOpen, in: characters, at: position) {
            var close = position + symOpen.count
            while close < characters.count, !has(symClose, in: characters, at: close) {
                if characters[close].isNewline { break }
                close += 1
            }
            guard has(symClose, in: characters, at: close) else { break }
            position = close + symClose.count
        }
        return position > index ? position : nil
    }

    private static func has(_ needle: [Character], in characters: [Character], at index: Int) -> Bool {
        guard index + needle.count <= characters.count else { return false }
        return Array(characters[index ..< index + needle.count]) == needle
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    private static let dynamicLetters: [Character] = ["f", "m", "n", "p", "r", "s", "z"]
    private static let symOpen = Array("<sym>")
    private static let symClose = Array("</sym>")
}
