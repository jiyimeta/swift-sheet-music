import SheetMusicCore
import SheetMusicFoundation

/// A direction's words, metronome and rehearsal marks as the elements MuseScore makes of them (`P2:3525-3699`), in
/// its `else if` order: a tempo text by its words, a tempo line (decided here, made by its own decoder), a Sticking,
/// a dynamic range's hyphen (which makes nothing here), then — when the direction has words, a rehearsal or a
/// metronome — a tempo text by its sound tempo, or else a staff text, a system text, a play-technique annotation or an
/// Expression, or else its rehearsal marks; a direction with none of those but a sound tempo is a hidden tempo. Only
/// one of these is made.
extension MusicXMLDirectionDecoder {
    static func appendTexts(
        _ facts: MusicXMLDirectionFacts, staff: Int, tick: Fraction, context: Context, to output: inout Output,
    ) {
        // A repeat direction's words are its marker's or jump's text (`handleRepeats` clears them).
        let words = facts.sound.isRepeat ? "" : facts.wordsXML
        let traits = MusicXMLTextTraits(
            xmlText: words, placement: facts.placement, isScoreTopStaff: context.partIndex == 0 && staff == 0,
            hasMetronome: facts.hasMetronome, soundTempo: facts.sound.tempo, isSystemDirection: facts.isSystem,
            soundTechnique: facts.sound.technique, infers: context.options.inferTextType,
            hasRehearsal: !facts.rehearsals.isEmpty,
        )
        let plainWords = MusicXMLFormattedWords.simplified(MusicXMLFormattedWords.plainText(ofXMLText: words))
        if traits.infers, MusicXMLWordsClassifier.isLikelyTempoText(traits, plain: plainWords) {
            appendTempoTextByWords(facts, words: words, tick: tick, context: context, to: &output)
            return
        }
        let kind = MusicXMLWordsClassifier.classify(traits)
        switch kind {
        case .tempoLine:
            // Made by the tempo-line decoder; until it lands, these words are dropped as before.
            return
        case .sticking:
            appendSticking(facts, words: words, staff: staff, tick: tick, context: context, to: &output)
            return
        default:
            break
        }
        // The hyphen of a dynamic range belongs to its dynamic (`appendDynamics`), which is all it makes.
        if isLikelyDynamicRange(facts, context: context) { return }
        guard !words.isEmpty || !facts.rehearsals.isEmpty || facts.hasMetronome else {
            appendHiddenTempo(facts, tick: tick, context: context, to: &output)
            return
        }
        if facts.sound.tempo > 0.1 {
            appendTempoTextBySound(facts, words: words, tick: tick, context: context, to: &output)
        } else if !words.isEmpty || facts.hasMetronome {
            let xmlText = words + facts.metronomeXML
            appendStaffKindText(kind, facts, xmlText: xmlText, staff: staff, tick: tick, context: context, to: &output)
        } else {
            appendRehearsals(facts, staff: staff, tick: tick, to: &output)
        }
    }

    /// A Sticking keeps only the words (`P2:3550-3566`). It is styled below: only "above" is an override.
    private static func appendSticking(
        _ facts: MusicXMLDirectionFacts, words: String, staff: Int, tick: Fraction, context: Context,
        to output: inout Output,
    ) {
        let (plain, markup) = MusicXMLFormattedWords.carrier(fromXMLText: words)
        var properties = ElementProperties(visible: facts.visible, color: facts.color)
        if facts.placement == "above" { properties.placement = .above }
        let sticking = Sticking(text: plain, elementProperties: properties, preservedTextMarkup: markup)
        output.events.append(MusicXMLDirectionEvent(
            measure: context.measure, staff: staff, tick: tick, payload: .voice(.sticking(sticking)),
        ))
    }

    /// The words and the metronome as an Expression, a system text, a play-technique annotation or a staff text
    /// (`P2:3587-3605`).
    private static func appendStaffKindText(
        _ kind: MusicXMLTextKind, _ facts: MusicXMLDirectionFacts, xmlText: String, staff: Int, tick: Fraction,
        context: Context, to output: inout Output,
    ) {
        let (plain, markup) = MusicXMLFormattedWords.carrier(fromXMLText: xmlText)
        switch kind {
        case .tempoText, .tempoLine, .sticking:
            // Decided before a text of this kind is made.
            return
        case .expression:
            let properties = ElementProperties(visible: facts.visible, color: facts.color)
            let expression = ExpressionText(text: plain, elementProperties: properties, preservedTextMarkup: markup)
            output.events.append(MusicXMLDirectionEvent(
                measure: context.measure, staff: staff, tick: tick, payload: .voice(.expression(expression)),
            ))
        case .systemText, .playTechnique, .staffText:
            var text = StaffText(
                text: plain, color: facts.color, isSystemText: kind == .systemText, visible: facts.visible,
                preservedTextMarkup: markup,
            )
            // Staff text, system text and a technique are styled above: only "below" is an override.
            if facts.placement == "below" { text.elementProperties.placement = .below }
            if case let .playTechnique(technique) = kind {
                text.annotation = .playTechnique(technique, playsBack: true)
            }
            output.systemElements.append(SystemPlacement(
                staff: staff, position: MeasurePosition(offset: tick), element: .staffText(text),
            ))
        }
    }

    /// A direction whose only text is its rehearsal marks, with no sound tempo: the marks, at the tick on the
    /// direction's staff (`P2:3606-3617`).
    private static func appendRehearsals(
        _ facts: MusicXMLDirectionFacts, staff: Int, tick: Fraction, to output: inout Output,
    ) {
        for mark in facts.rehearsals {
            output.systemElements.append(SystemPlacement(
                staff: staff, position: MeasurePosition(offset: tick), element: .rehearsalMark(mark),
            ))
        }
    }
}
