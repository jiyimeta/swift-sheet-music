import SheetMusicCore
import SheetMusicFoundation

/// The element MuseScore makes of a direction's words (`MusicXmlParserDirection::direction`).
enum MusicXMLTextKind: Sendable, Equatable {
    case tempoText
    case tempoLine(GradualTempoChangeType)
    case sticking
    case expression
    case systemText
    case playTechnique(PlayingTechnique)
    case staffText
}

/// What the classification of a direction's words reads.
struct MusicXMLTextTraits: Sendable, Equatable {
    /// The words as MuseScore xml text (`MusicXMLFormattedWords.xmlText(of:)`).
    var xmlText: String
    /// The direction's placement, "above" or "below", when it has one.
    var placement: String?
    /// The direction stands on the score's first staff (part 0, staff 0) — MuseScore's `track2staff(track) == 0`.
    var isScoreTopStaff: Bool
    /// The direction carries a `<metronome>` (MuseScore's non-empty `m_metroText`).
    var hasMetronome: Bool
    /// `<sound tempo>`, 0 when absent.
    var soundTempo: Double
    /// `system="only-top"`.
    var isSystemDirection: Bool
    /// The technique `<sound>` asks for (`pizzicato`, `<play>`).
    var soundTechnique: PlayingTechnique?
    /// `MusicXMLImportOptions.inferTextType`.
    var infers: Bool
    /// The direction carries a `<rehearsal>` (MuseScore's non-empty `m_rehearsalText`), which rules out a Sticking.
    var hasRehearsal = false
}

/// The decision `MusicXmlParserDirection::direction` takes about a direction's words (`importmusicxmlpass2.cpp`,
/// `P2:3525-3604`).
enum MusicXMLWordsClassifier {
    static func classify(_ traits: MusicXMLTextTraits) -> MusicXMLTextKind {
        let plain = MusicXMLFormattedWords.simplified(MusicXMLFormattedWords.plainText(ofXMLText: traits.xmlText))
        if traits.infers {
            if isLikelyTempoText(traits, plain: plain) { return .tempoText }
            if isLikelyTempoLine(traits, plain: plain) { return .tempoLine(tempoLineType(for: plain)) }
            if isLikelySticking(plain: plain, traits) { return .sticking }
        }
        if traits.soundTempo > 0.1 { return .tempoText }
        if traits.xmlText.hasSubstring("<i>"), !traits.hasMetronome, traits.placement == "below" { return .expression }
        if traits.isSystemDirection { return .systemText }
        if let found = traits.soundTechnique ?? (traits.infers ? technique(in: plain) : nil) {
            return .playTechnique(found)
        }
        return .staffText
    }

    /// A tempo line's type from its words (`getTempoChangeTypeFromString`, `P2:3381-3407`).
    static func tempoLineType(for words: String) -> GradualTempoChangeType {
        let text = words.lowercased()
        if text.hasSubstring("accel") { return .accelerando }
        if text.hasSubstring("allarg") { return .allargando }
        if text == "calando" { return .calando }
        if text.hasSubstring("lent") { return .lentando }
        if text == "morendo" { return .morendo }
        if text == "precipitando" { return .precipitando }
        if text.hasSubstring("rall") { return .rallentando }
        if text.hasSubstring("rit") { return .ritardando }
        if text.hasSubstring("smorz") { return .smorzando }
        if text == "stringendo" { return .stringendo }
        return .undefined
    }

    /// `isLikelyTempoText` (`P2:3905-3926`): words on the score's top staff, not italic, not quoted, not below, that
    /// hold one of MuseScore's tempo words. `plain` is the simplified plain text. Internal: the tempo-text decoder
    /// tells a text that is tempo by its words from one that is tempo by its `<sound tempo>`.
    static func isLikelyTempoText(_ traits: MusicXMLTextTraits, plain: String) -> Bool {
        guard traits.infers, !traits.xmlText.isEmpty, !traits.xmlText.hasSubstring("<i>"),
              !isQuoted(traits.xmlText), traits.placement != "below", traits.isScoreTopStaff
        else { return false }
        let lower = plain.lowercased()
        return tempoWords.contains { lower.hasSubstring($0) }
    }

    /// `isLikelyTempoLine` (`P2:3952-3964`): a line word starts the text or follows a whitespace character.
    static func isLikelyTempoLine(_ traits: MusicXMLTextTraits, plain: String) -> Bool {
        guard traits.infers, !traits.xmlText.isEmpty, !isQuoted(traits.xmlText), traits.placement != "below",
              traits.isScoreTopStaff
        else { return false }
        let lower = plain.lowercased()
        var index = lower.startIndex
        var atWordStart = true
        while index < lower.endIndex {
            if atWordStart, tempoLineWords.contains(where: { lower[index...].hasPrefix($0) }) { return true }
            atWordStart = lower[index].isWhitespace
            index = lower.index(after: index)
        }
        return false
    }

    /// `isLikelySticking` (`P2:4979-4991`): only the letters `lrbLRB`, with no rehearsal, metronome or sound tempo.
    static func isLikelySticking(plain: String, _ traits: MusicXMLTextTraits) -> Bool {
        guard traits.infers, !plain.isEmpty, !traits.hasRehearsal, !traits.hasMetronome, traits.soundTempo < 0.1
        else { return false }
        return plain.allSatisfy { "lrbLRB".contains($0) }
    }

    /// `getPlayingTechnique` (`P2:5007-5054`): the lower-cased plain words without `.,;:`, scanned against MuseScore's
    /// ordered table; the first key the words contain decides, and a palm mute is no technique.
    static func technique(in plain: String) -> PlayingTechnique? {
        let words = String(plain.lowercased().filter { !".,;:".contains($0) })
        for (key, technique) in techniqueTable where words.hasSubstring(key) {
            return technique
        }
        return nil
    }

    private static func isQuoted(_ xmlText: String) -> Bool {
        xmlText.hasSubstring("\u{201C}") || xmlText.hasSubstring("\u{201D}")
    }

    /// `P2:3916-3918`.
    private static let tempoWords = [
        "adag", "alleg", "andant", "a tempo", "ballad", "brisk", "determination", "dolce", "expressive", "fast",
        "free", "gently", "grave", "larg", "lento", "stesso tempo", "lively", "maestoso", "moderat", "mosso", "prest",
        "rubato", "slow", "straight", "tango", "tempo i", "tenderly", "triumphant", "vivace",
    ]

    /// `P2:3961`.
    private static let tempoLineWords = ["accel", "faster", "mosso", "rit", "rubato", "slower", "stretto"]

    /// `P2:5018-5046`, in MuseScore's order; `nil` is its `Undefined`.
    private static let techniqueTable: [(String, PlayingTechnique?)] = [
        ("palm mute", nil), ("palmmute", nil), ("without mute", .open), ("distortion", .distortion),
        ("senza sord", .open), ("harmonics", .harmonics), ("overdrive", .overdrive), ("sul pont", .sulPonticello),
        ("sul tast", .sulTasto), ("con sord", .mute), ("detache", .detache), ("martele", .martele),
        ("natural", .natural), ("no mute", .open), ("unmuted", .open), ("vibrato", .vibrato), ("legato", .legato),
        ("normal", .natural), ("legno", .colLegno), ("open", .open), ("arco", .natural), ("jazz", .jazzTone),
        ("mute", .mute), ("pizz", .pizzicato), ("sord", .mute), ("trem", .tremolo), ("ord", .natural),
    ]
}
