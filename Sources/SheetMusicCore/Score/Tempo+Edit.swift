import SheetMusicFoundation

extension Tempo {
    /// Writes `marking` (`SetTempo`): the number and beat, `<play>` when it says, and the text as its `TextEdit` says —
    /// `.keep` leaving the words to the number-edit rule when the number or the beat moved (`applyNumberEdit`).
    ///
    /// `reported` is what `SetTempo.current` handed the host for this beat — the number and beat the marking is being
    /// compared with. It differs from the stored tempo for a following "a tempo" / "tempo primo", whose stored number
    /// is meaningless and which `current` reports as the tempo it reinstates: a host that only toggles `playsBack`
    /// hands that tempo back unchanged, and must not be read as having edited the number. `nil` compares with the
    /// stored tempo.
    mutating func apply(_ marking: SetTempo.Marking, reported: SetTempo.Marking? = nil) {
        let basis = reported ?? SetTempo.Marking(beatsPerSecond: beatsPerSecond, beatNote: beatNote, beatDots: beatDots)
        // The sender's stamp wins; without one (an older sender) the edit is inferred from what this replica reported.
        let numberChanged = marking.numberEdit ?? (marking.beatsPerSecond != basis.beatsPerSecond
            || marking.beatNote != basis.beatNote || marking.beatDots != basis.beatDots)
        if numberChanged {
            beatsPerSecond = marking.beatsPerSecond
            beatNote = marking.beatNote
            beatDots = marking.beatDots
        }
        if let playsBack = marking.playsBack {
            self.playsBack = playsBack
        }
        switch marking.text {
        case .derive:
            text = nil
            preservedTextMarkup = nil
            followText = true
            textType = .normal
        case let .set(newText):
            text = newText
            preservedTextMarkup = nil
        case .keep:
            if numberChanged {
                applyNumberEdit()
            }
        }
    }

    /// What a new number or beat does to the words (spec 2026-10-14 §5.6, the owner's decision b): only the equation
    /// changes, the words around it stay. The text is read as MuseScore reads it (`TempoTextEquation`), and the
    /// invariant held afterwards is that the equation the text prints equals what plays, in the text's own beat glyph:
    ///
    /// - a derived text prints the new number by itself;
    /// - a text that is an equation and nothing else becomes derived;
    /// - words around an equation, while the marking follows its text, get the number rewritten in the text's own
    ///   beat — in the plain text and in the markup, so the glyph and the formatting stay — and, when the host changed
    ///   the beat itself, the glyph rewritten to the new beat with the number counted in it;
    /// - words alone, a modulation, or a marking that does not follow its text keep their words: the number changes
    ///   what plays only.
    ///
    /// **Deviation from MuseScore:** an "a tempo" or "tempo primo" whose number is edited becomes `.normal`, words
    /// kept. MuseScore's `updateTempo` never changes a marking's type, so there the edited number of an "a tempo" is
    /// simply ignored by playback; here an edit that would be ignored is worse than the type change.
    mutating func applyNumberEdit() {
        textType = .normal
        guard text != nil else { return }
        switch TempoTextEquation(displayedRichText) {
        case .metronome(_, _, true):
            text = nil
            preservedTextMarkup = nil
            followText = true
        case let .metronome(textBeat, _, false) where followText:
            rewriteEquation(textBeatQuarters: textBeat)
        default:
            break
        }
    }

    /// Rewrites the equation the classifier matched (`TempoTextEquation`): the first one in document order whose beat
    /// is `textBeatQuarters`. While the marking's beat is the text's own, only the number is written, counted in that
    /// beat; when the host changed the beat, the glyph is rewritten too (the table the derived text uses) and the
    /// number counted in the new beat.
    ///
    /// The markup is rewritten only when its plain text then equals the plain-text rewrite — the two sides change the
    /// same equation or neither does. Otherwise the markup (stale now) is dropped and the plain text is rewritten
    /// alone, anchored on the same equation: a glyph that lives only in the markup (a `<sym>`) is not in the plain
    /// text, so there is nothing to rewrite and the number is counted in the text's own beat, which keeps the equation
    /// true to what plays. When no anchor can be established, the text is regenerated from the marking's beat and
    /// number (derived) rather than a guessed number rewritten. That is a defensive fallback: no known input reaches
    /// it (the classifier and the locators read the same equations), so it has no test.
    private mutating func rewriteEquation(textBeatQuarters: Double) {
        let reading = displayedRichText
        let sameBeat = abs(textBeatQuarters - beatLengthInQuarters) < 1e-9
        let inTextBeat = Self.printedNumber(beatsPerSecond * 60 / textBeatQuarters)
        let replacement = sameBeat ? nil : metronomeMarking
        let glyphs = replacement?.symbolNames
        let number = replacement?.number ?? inTextBeat
        guard let plain = text else { return }
        guard let match = Self.equationMatch(in: plain, reading: reading, quarters: textBeatQuarters) else {
            text = nil
            preservedTextMarkup = nil
            followText = true
            return
        }
        if let markup = preservedTextMarkup,
           let rewritten = markup.replacingEquation(glyphs: glyphs, number: number, quarters: textBeatQuarters),
           RichText(markup: rewritten).plainText == Self.spliced(plain, match, glyphs: glyphs, number: number)
        {
            let rewrittenPlain = RichText(markup: rewritten).plainText
            preservedTextMarkup = PreservedTextMarkup(content: rewritten.content, derivedText: rewrittenPlain)
            text = rewrittenPlain
            return
        }
        preservedTextMarkup = nil
        let glyphInText = glyphs != nil && !match.glyph.isEmpty
        text = Self.spliced(plain, match, glyphs: glyphs, number: glyphInText ? number : inTextBeat)
    }
}
