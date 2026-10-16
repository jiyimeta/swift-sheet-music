import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// What a `<direction>` says, read in one pass over its children as `MusicXmlParserDirection::direction` and
/// `directionType` read them (`importmusicxmlpass2.cpp`, `P2:3447-3486`, `4017-4105`).
struct MusicXMLDirectionFacts: Sendable, Equatable {
    /// `placement="above|below"`, else the side `default-y` puts it on (`placement()`, `P2:3372-3379`).
    var placement: String?
    /// `system="only-top"`.
    var isSystem = false
    /// `print-object != "no"` on the last `<direction-type>` child (`m_visible`, `P2:4023`).
    var visible = true
    /// `color` on the last `<direction-type>` child (`m_color`, `P2:4035`).
    var color: ScoreColor?
    /// Every `<words>` as xml text, in order, plus the glyphs MuseScore writes into the words as `<sym>`.
    var wordsXML = ""
    /// The last `<metronome>` (`m_metroText` and `m_tpoMetro`, which each `<metronome>` sets again).
    var metronome: MusicXMLMetronome.Parsed?
    /// `default-y` parsed on the last `<direction-type>` child (`m_hasDefaultY`, `P2:4021`): MuseScore then holds a
    /// text back with the measure's delayed directions (`hasTotalY`, `P2:3672-3677`).
    var hasDefaultY = false
    /// The `<rehearsal>` marks.
    var rehearsals: [RehearsalMark] = []
    /// What `<sound>` says — its `tempo` already replaced by the metronome's when it has none.
    var sound = MusicXMLSoundFacts()

    /// The metronome's text is not empty (MuseScore's non-empty `m_metroText`).
    var hasMetronome: Bool {
        !metronomeXML.isEmpty
    }

    /// The metronome's xml text, or "".
    var metronomeXML: String {
        metronome?.xmlText ?? ""
    }

    init(_ direction: XMLTreeNode) {
        let explicitPlacement = direction.attributes["placement"].flatMap { $0.isEmpty ? nil : $0 }
        isSystem = direction.attributes["system"] == "only-top"
        var defaultY: Double?
        for type in direction.all("direction-type") {
            for child in type.children {
                // Every child resets these, as `directionType` reads them per child: the last one decides.
                defaultY = child.attributes["default-y"].flatMap { Double($0) }.map { $0 * -0.1 }
                visible = child.attributes["print-object"] != "no"
                color = child.attributes["color"].flatMap { MusicXMLColor.parse($0) }
                read(child)
            }
        }
        placement = explicitPlacement ?? defaultY.map { $0 < 0 ? "above" : "below" }
        hasDefaultY = defaultY != nil
        rehearsals = MusicXMLRehearsalDecoder.decode(direction)
        for node in direction.all("sound") {
            sound.read(node)
        }
        // Sibelius 7.1.3 writes a metronome without `<sound tempo>`: the metronome's tempo stands in, before anything
        // reads the tempo (`P2:3494-3499`).
        if sound.tempo < 0.1, let metronomeTempo = metronome?.quarterBeatsPerMinute, metronomeTempo > 0.1 {
            sound.tempo = metronomeTempo
        }
    }

    /// One `<direction-type>` child's contribution to the words (`P2:4037-4103`). `<segno/>` and `<coda/>` add
    /// nothing here: the repeat decoding owns their glyph.
    private mutating func read(_ child: XMLTreeNode) {
        switch child.name {
        case "words":
            wordsXML += MusicXMLFormattedWords.xmlText(of: child)
        case "metronome":
            metronome = MusicXMLMetronome.parse(child)
        case "eyeglasses":
            wordsXML += "<sym>miscEyeglasses</sym>"
        case "symbol":
            let name = child.text
            if !name.isEmpty { wordsXML += "<sym>\(name)</sym>" }
        case "string-mute":
            switch child.attributes["type"] {
            case "on": wordsXML += "<sym>stringsMuteOn</sym>"
            case "off": wordsXML += "<sym>stringsMuteOff</sym>"
            default: break
            }
        default:
            break
        }
    }
}

/// What a direction's `<sound>` says (`MusicXmlParserDirection::sound` and `play`, `P2:4115-4165`).
struct MusicXMLSoundFacts: Sendable, Equatable {
    /// `tempo`, 0 when absent.
    var tempo = 0.0
    var dynamics: String?
    var coda: String?
    var dacapo: String?
    var dalsegno: String?
    var fine: String?
    var segno: String?
    var tocoda: String?
    /// `pizzicato="yes|no"`, then `<play><mute>` / `<other-play type>`, the later one winning.
    var technique: PlayingTechnique?

    /// A repeat direction: its words are the marker's or the jump's text, not a text element of their own
    /// (`handleRepeats` clears them, `P2:4743-4745`).
    var isRepeat: Bool {
        [coda, dacapo, dalsegno, fine, segno, tocoda].contains { $0 != nil }
    }

    /// Each `<sound>` sets every attribute again, as MuseScore reads it; the technique carries over until one sets it.
    mutating func read(_ node: XMLTreeNode) {
        tempo = node.attributes["tempo"].flatMap { Double($0) } ?? 0
        dynamics = node.attributes["dynamics"]
        coda = node.attributes["coda"]
        dacapo = node.attributes["dacapo"]
        dalsegno = node.attributes["dalsegno"]
        fine = node.attributes["fine"]
        segno = node.attributes["segno"]
        tocoda = node.attributes["tocoda"]
        switch node.attributes["pizzicato"] {
        case "yes": technique = .pizzicato
        case "no": technique = .natural
        default: break
        }
        for play in node.all("play") {
            for child in play.children {
                if child.name == "mute" {
                    technique = child.text == "off" ? .open : .mute
                } else if child.name == "other-play" {
                    // `TConv::fromXml` with `Undefined` as the fallback: a token MuseScore does not know is none.
                    let token = PlayingTechnique(mscxToken: child.attributes["type"] ?? "")
                    if case .other = token { technique = nil } else { technique = token }
                }
            }
        }
    }
}

/// MusicXML's `color`: `#RRGGBB` or `#AARRGGBB`.
enum MusicXMLColor {
    static func parse(_ text: String) -> ScoreColor? {
        guard text.first == "#" else { return nil }
        let digits = Array(text.dropFirst())
        guard digits.count == 6 || digits.count == 8 else { return nil }
        var bytes: [Int] = []
        var index = 0
        while index < digits.count {
            guard let byte = Int(String(digits[index ..< index + 2]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        if bytes.count == 4 {
            return ScoreColor(red: bytes[1], green: bytes[2], blue: bytes[3], alpha: bytes[0])
        }
        return ScoreColor(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: 255)
    }
}
