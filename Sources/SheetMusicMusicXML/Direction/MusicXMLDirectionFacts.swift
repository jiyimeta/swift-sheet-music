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
    /// MuseScore's `m_dynamicsList`: every `<dynamics>` child in order — an `<other-dynamics>` as its text, any other
    /// as its element name (`P2:4218-4225`) — then, when inferring, each `<words>` that is a dynamic, as its subtype
    /// (`textToDynamic`, `P2:4535-4537`).
    var dynamics: [String] = []
    /// `color` on the last `<dynamics>` (`m_dynamicsColor`, `P2:4216`).
    var dynamicsColor: ScoreColor?
    /// MuseScore's `m_dynaVelocity` as a number, `nil` while it is empty: a words dynamic sets it to its table
    /// velocity ÷ 0.9 (`P2:4536`), then each `<sound>` sets it again to its `dynamics` (`P2:4124`) — a value that is no
    /// number reads as 0 (`String::toDouble`).
    var dynamicsVelocity: Double?
    /// The `<wedge>` starts and stops, in order (`MusicXmlParserDirection::wedge`, `P2:5470-5514`).
    var wedges: [MusicXMLWedgeFact] = []
    /// The `<octave-shift>` starts and stops, in order (`MusicXmlParserDirection::octaveShift`, `P2:5279-5330`).
    var octaveShifts: [MusicXMLOctaveShiftFact] = []
    /// The `<pedal>` marks, in order (`MusicXmlParserDirection::pedal`, `P2:5340-5458`).
    var pedals: [MusicXMLPedalFact] = []
    /// The direction's own `placement` attribute (`m_placement`, `P2:3447`), which an ottava's side falls back from
    /// to its styled side without consulting `default-y` (`P2:5297`, `5306`).
    var placementAttribute: String?
    /// The `<bracket>` and `<dashes>` starts and stops, in order (`P2:5095-5258`), each start holding the words read
    /// before it, which it takes out of `wordsXML`.
    var lines: [MusicXMLLineFact] = []
    /// When inferring, the simplified plain text of the last `<words>` that holds "cresc" or "dim", which MuseScore
    /// takes out of the words to start a hairpin line (`textToCrescLine`, `P2:4543-4564`).
    var crescLineWords: String?
    /// The direction makes a repeat (`MusicXMLRepeatClassifier`): its words are the marker's or the jump's text, not
    /// a text element of their own (`handleRepeats` clears them, `P2:~4711-4745`).
    var isRepeat = false

    /// The metronome's text is not empty (MuseScore's non-empty `m_metroText`).
    var hasMetronome: Bool {
        !metronomeXML.isEmpty
    }

    /// The metronome's xml text, or "".
    var metronomeXML: String {
        metronome?.xmlText ?? ""
    }

    /// MuseScore's `m_tpoMetro`: the quarter-note tempo the last `<metronome>`, or the last `<words>` read as a
    /// metronome (`MusicXMLMetronomeWords`), implies; each sets it again (`P2:4038`, `4974`).
    var metronomeTempo = 0.0

    /// `infers` is `MusicXMLImportOptions.inferTextType`, which lets words be a dynamic or a metronome; `software` is
    /// the exporter, whose habits bend the words: Finale's dynamic letters (`P2:4519`), Sibelius's metronome letters
    /// (`P2:4928`).
    init(_ direction: XMLTreeNode, infers: Bool, software: MusicXMLExporterSoftware = .other) {
        let explicitPlacement = direction.attributes["placement"].flatMap { $0.isEmpty ? nil : $0 }
        isSystem = direction.attributes["system"] == "only-top"
        var defaultY: Double?
        for type in direction.all("direction-type") {
            for child in type.children {
                // Every child resets these, as `directionType` reads them per child: the last one decides.
                defaultY = child.attributes["default-y"].flatMap { Double($0) }.map { $0 * -0.1 }
                visible = child.attributes["print-object"] != "no"
                color = child.attributes["color"].flatMap { MusicXMLColor.parse($0) }
                // `placement()` as a line reads it while its element is read (`P2:5243`).
                let placementNow = explicitPlacement ?? defaultY.map { $0 < 0 ? "above" : "below" }
                read(child, infers: infers, software: software, placement: placementNow)
            }
        }
        placementAttribute = explicitPlacement
        placement = explicitPlacement ?? defaultY.map { $0 < 0 ? "above" : "below" }
        hasDefaultY = defaultY != nil
        rehearsals = MusicXMLRehearsalDecoder.decode(direction)
        isRepeat = MusicXMLRepeatClassifier.classify(direction, source: MusicXMLRepeatSource(direction)) != nil
        for node in direction.all("sound") {
            sound.read(node)
            dynamicsVelocity = sound.dynamics.flatMap { $0.isEmpty ? nil : (Double($0) ?? 0) }
        }
        // Sibelius 7.1.3 writes a metronome without `<sound tempo>`: the metronome's tempo stands in, before anything
        // reads the tempo (`P2:3494-3499`).
        if sound.tempo < 0.1, metronomeTempo > 0.1 {
            sound.tempo = metronomeTempo
        }
    }

    /// One `<direction-type>` child's contribution to the words (`P2:4037-4103`). `<segno/>` and `<coda/>` add
    /// nothing here: the repeat decoding owns their glyph.
    private mutating func read(
        _ child: XMLTreeNode, infers: Bool, software: MusicXMLExporterSoftware, placement: String?,
    ) {
        switch child.name {
        case "words":
            readWords(child, infers: infers, software: software)
        case "bracket", "dashes":
            readLine(child, placement: placement)
        case "dynamics":
            dynamicsColor = child.attributes["color"].flatMap { MusicXMLColor.parse($0) }
            for mark in child.children {
                dynamics.append(mark.name == "other-dynamics" ? mark.text : mark.name)
            }
        case "metronome":
            let parsed = MusicXMLMetronome.parse(child)
            metronome = parsed
            metronomeTempo = parsed.quarterBeatsPerMinute
        case "wedge":
            if let wedge = MusicXMLWedgeFact(child), !wedges.contains(where: { $0.repeats(wedge) }) {
                wedges.append(wedge)
            }
        case "octave-shift":
            if let shift = MusicXMLOctaveShiftFact(child), !octaveShifts.contains(where: { $0.repeats(shift) }) {
                octaveShifts.append(shift)
            }
        case "pedal":
            if let pedal = MusicXMLPedalFact(child) { pedals.append(pedal) }
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

    /// One `<words>`: `textToDynamic` then `textToCrescLine` take one that is a dynamic, or that holds "cresc" or
    /// "dim", out of the words (`P2:4044-4045`); `handleTempo` then reads what is left as a metronome when it is one
    /// (`P2:4046`), which rewrites the words and sets the metronome tempo. Each is only done when inferring.
    private mutating func readWords(_ child: XMLTreeNode, infers: Bool, software: MusicXMLExporterSoftware) {
        let part = MusicXMLFormattedWords.xmlText(of: child)
        let plain = MusicXMLFormattedWords.simplified(MusicXMLFormattedWords.plainText(ofXMLText: part))
        if infers, let subtype = MusicXMLDynamicText.wordsDynamic(part, finale: software == .finale) {
            dynamics.append(subtype)
            dynamicsVelocity = (Double(Dynamic.defaultVelocity(for: subtype)) / 0.9).rounded()
        } else if infers, plain.hasSubstring("cresc") || plain.hasSubstring("dim") {
            crescLineWords = plain
        } else if infers, let words = MusicXMLDirectionDecoder.metronomeWords(
            plain: plain, software: software, fontFamily: child.attributes["font-family"],
        ) {
            wordsXML += words.xmlText
            if let tempo = words.quarterBeatsPerMinute { metronomeTempo = tempo }
        } else {
            wordsXML += part
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

/// MusicXML's `color`: `#RRGGBB` or `#AARRGGBB`. An opaque black is `nil`: it is every element's default color, and
/// MuseScore writes a property only when it differs from its default, so its file carries no color for it.
enum MusicXMLColor {
    static func parse(_ text: String) -> ScoreColor? {
        let color = parsed(text)
        return color == ScoreColor(red: 0, green: 0, blue: 0, alpha: 255) ? nil : color
    }

    private static func parsed(_ text: String) -> ScoreColor? {
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
