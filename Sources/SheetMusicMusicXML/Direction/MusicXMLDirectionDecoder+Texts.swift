import SheetMusicCore
import SheetMusicFoundation

/// A direction's words and rehearsal marks as the elements MuseScore makes of them (`P2:3525-3682`): a staff text, a
/// system text, a play-technique annotation, an Expression or a Sticking; a tempo text and a tempo line are decided
/// here but made by their own decoders. A rehearsal mark stands only when the direction has no words, no metronome and
/// no sound tempo.
extension MusicXMLDirectionDecoder {
    static func appendTexts(
        _ facts: MusicXMLDirectionFacts, staff: Int, tick: Fraction, context: Context, to output: inout Output,
    ) {
        // A repeat direction's words are its marker's or jump's text (`handleRepeats` clears them).
        let words = facts.sound.isRepeat ? "" : facts.wordsXML
        guard !words.isEmpty else {
            appendRehearsals(facts, staff: staff, tick: tick, to: &output)
            return
        }
        let traits = MusicXMLTextTraits(
            xmlText: words, placement: facts.placement, isScoreTopStaff: context.partIndex == 0 && staff == 0,
            hasMetronome: facts.hasMetronome, soundTempo: facts.sound.tempo, isSystemDirection: facts.isSystem,
            soundTechnique: facts.sound.technique, infers: context.options.inferTextType,
            hasRehearsal: !facts.rehearsals.isEmpty,
        )
        let (plain, markup) = MusicXMLFormattedWords.carrier(fromXMLText: words)
        let properties = ElementProperties(visible: facts.visible, color: facts.color)
        switch MusicXMLWordsClassifier.classify(traits) {
        case .tempoText, .tempoLine:
            // Made by the tempo decoders; until they land, these words are dropped as before.
            return
        case .expression:
            let expression = ExpressionText(text: plain, elementProperties: properties, preservedTextMarkup: markup)
            output.events.append(MusicXMLDirectionEvent(
                measure: context.measure, staff: staff, tick: tick, payload: .voice(.expression(expression)),
            ))
        case .sticking:
            var stickingProperties = properties
            // Sticking is styled below: only "above" is an override.
            if facts.placement == "above" { stickingProperties.placement = .above }
            let sticking = Sticking(text: plain, elementProperties: stickingProperties, preservedTextMarkup: markup)
            output.events.append(MusicXMLDirectionEvent(
                measure: context.measure, staff: staff, tick: tick, payload: .voice(.sticking(sticking)),
            ))
        case let kind:
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

    /// A direction without words: its rehearsal marks, at the tick on the direction's staff, unless a metronome or a
    /// sound tempo makes it a tempo direction (`P2:3569-3617`).
    private static func appendRehearsals(
        _ facts: MusicXMLDirectionFacts, staff: Int, tick: Fraction, to output: inout Output,
    ) {
        guard !facts.hasMetronome, facts.sound.tempo <= 0.1 else { return }
        for mark in facts.rehearsals {
            output.systemElements.append(SystemPlacement(
                staff: staff, position: MeasurePosition(offset: tick), element: .rehearsalMark(mark),
            ))
        }
    }
}
