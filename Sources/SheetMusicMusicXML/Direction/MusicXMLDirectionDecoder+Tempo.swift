import SheetMusicCore
import SheetMusicFoundation

/// The tempo markings MuseScore makes of a direction (`MusicXmlParserDirection::direction`, `importmusicxmlpass2.cpp`)
/// and of a `<sound tempo>` standing directly in a measure (`MusicXmlParserPass2::measure`). Each is a `TempoText`
/// whose xml text is built as MuseScore builds it and whose tempo is the sound's (the metronome's standing in, see
/// `MusicXMLDirectionFacts`); none sets an a-tempo or tempo-primo type. `canAddTempoText` (`P2:2692-2707`) is asked at
/// the clock where the direction stands, and the marking is recorded where it is placed, `tick` — the clock plus
/// `<offset>`. Every marking goes to the score's top staff (`addElemOffset`: "TempoText must be in track 0").
extension MusicXMLDirectionDecoder {
    /// Words that read as a tempo (`P2:3525-3538`): always made, as the words then the metronome. It plays the sound
    /// tempo, following its text when that holds an "=", unless a marking on the tick already blocks it; then it
    /// keeps `TempoText`'s default, 2 beats per second, and does not follow its text.
    static func appendTempoTextByWords(
        _ facts: MusicXMLDirectionFacts, words: String, tick: Fraction, context: Context, to output: inout Output,
    ) {
        let xmlText = words + facts.metronomeXML
        var beatsPerSecond = MusicXMLTempoRegistry.defaultBeatsPerSecond
        var followText = false
        if facts.sound.tempo > 0, context.registry.registry.canAdd(measure: context.measure, tick: context.now) {
            beatsPerSecond = Tempo.clampedBeatsPerSecond(facts.sound.tempo / 60)
            followText = MusicXMLFormattedWords.plainText(ofXMLText: xmlText).hasSubstring("=")
        }
        var tempo = tempoMarking(xmlText: xmlText, beatsPerSecond: beatsPerSecond, followText: followText)
        tempo.visible = facts.visible
        place(tempo, facts: facts, tick: tick, context: context, heldBack: false, to: &output)
    }

    /// Words, a rehearsal or a metronome with a sound tempo (`P2:3571-3585`): the words, a space when the metronome
    /// follows words that do not end in one, then the metronome, playing the sound tempo — or nothing at all when a
    /// marking on the tick blocks it. With a `default-y` MuseScore adds it with the measure's delayed directions, so it
    /// blocks only from the end of the measure (`P2:3672-3677`).
    static func appendTempoTextBySound(
        _ facts: MusicXMLDirectionFacts, words: String, tick: Fraction, context: Context, to output: inout Output,
    ) {
        guard context.registry.registry.canAdd(measure: context.measure, tick: context.now) else { return }
        let rawWords = withoutTags(words)
        let separator = !facts.hasMetronome || rawWords.isEmpty || rawWords.last == " " ? "" : " "
        let xmlText = words + separator + facts.metronomeXML
        let followText = MusicXMLFormattedWords.plainText(ofXMLText: xmlText).hasSubstring("=")
        var tempo = tempoMarking(
            xmlText: xmlText, beatsPerSecond: Tempo.clampedBeatsPerSecond(facts.sound.tempo / 60),
            followText: followText,
        )
        tempo.elementProperties.visible = facts.visible
        tempo.elementProperties.color = facts.color
        place(tempo, facts: facts, tick: tick, context: context, heldBack: facts.hasDefaultY, to: &output)
    }

    /// A direction with no words, rehearsal or metronome but a sound tempo (`P2:3683-3698`): a hidden "♩ = N" that
    /// follows its text, when no marking on the tick blocks it.
    static func appendHiddenTempo(
        _ facts: MusicXMLDirectionFacts, tick: Fraction, context: Context, to output: inout Output,
    ) {
        guard facts.sound.tempo > 0,
              context.registry.registry.canAdd(measure: context.measure, tick: context.now)
        else { return }
        let tempo = hiddenTempo(printedTempo: Tempo.printedNumber(facts.sound.tempo), quarterBPM: facts.sound.tempo)
        place(tempo, facts: facts, tick: tick, context: context, heldBack: false, to: &output)
    }

    /// The invisible marking MuseScore makes of a bare sound tempo: `"<sym>metNoteQuarterUp</sym> = " + printed`,
    /// hidden, following its text (`P2:3689-3694`, `2823-2828`).
    static func hiddenTempo(printedTempo: String, quarterBPM: Double) -> Tempo {
        var tempo = tempoMarking(
            xmlText: "<sym>metNoteQuarterUp</sym> = \(printedTempo)",
            beatsPerSecond: Tempo.clampedBeatsPerSecond(quarterBPM / 60), followText: true,
        )
        tempo.visible = false
        return tempo
    }

    /// A marking from its xml text, in `Tempo.decode`'s order: the beat read out of the printed number when the
    /// marking follows its text, then the text adopted — derived when it is exactly the marking this library prints.
    static func tempoMarking(xmlText: String, beatsPerSecond: Double, followText: Bool) -> Tempo {
        let (plain, markup) = MusicXMLFormattedWords.carrier(fromXMLText: xmlText)
        let beat = followText
            ? Tempo.beatUnit(inPrintedText: plain, beatsPerSecond: beatsPerSecond)
            : (note: NoteDuration.quarter, dots: 0)
        var tempo = Tempo(
            beatsPerSecond: beatsPerSecond, beatNote: beat.note, beatDots: beat.dots, followText: followText,
        )
        tempo.adoptText(markup, plainText: plain)
        return tempo
    }

    /// Into the tempo lane at `tick`, recorded where it is placed: now, or at the end of the measure for a marking
    /// MuseScore holds back. `placement="below"` is an override; above is the tempo style's own side.
    private static func place(
        _ tempo: Tempo, facts: MusicXMLDirectionFacts, tick: Fraction, context: Context, heldBack: Bool,
        to output: inout Output,
    ) {
        var tempo = tempo
        if facts.placement == "below" { tempo.elementProperties.placement = .below }
        output.tempoElements.append(PositionedSystemElement(
            position: MeasurePosition(offset: tick), element: .tempo(tempo),
        ))
        if heldBack {
            context.registry.registry.recordAtMeasureEnd(
                measure: context.measure, tick: tick, beatsPerSecond: tempo.beatsPerSecond,
            )
        } else {
            context.registry.registry.record(measure: context.measure, tick: tick, beatsPerSecond: tempo.beatsPerSecond)
        }
    }

    /// The xml text with every `<…>` removed, as MuseScore's `rawWordsText.remove(std::regex("(<.*?>)"))` leaves it
    /// (`P2:3575-3577`): an element's characters stay, entities are not read.
    static func withoutTags(_ xmlText: String) -> String {
        var result = ""
        var inTag = false
        for character in xmlText {
            if inTag {
                if character == ">" { inTag = false }
            } else if character == "<" {
                inTag = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
