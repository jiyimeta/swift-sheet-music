import SheetMusicFoundation

/// The fields the edit-command parity project (spec 2026-09-02 §2.5) brought under the fingerprint.
///
/// Two rules, both chosen so that a score in which none of these fields is set produces the exact byte stream it
/// did before this file existed — which is what keeps every committed replay golden byte-identical:
///
/// - **Measure flags and element properties are fed BY OCCUPANTS.** A field contributes bytes only when it holds a
///   non-default value, and always as a unique non-zero tag (21 and up, so no tag can be mistaken for a
///   `VoiceElement` case tag 0…16 or for a presence byte) followed by its value. The tag is what keeps
///   `endRepeatCount = 2` and `measureRepeatCount = 2` apart; the fixed-arity prefix of each measure block is what
///   keeps "flag on measure 3" and "flag on measure 4" apart.
/// - **The marker `VoiceElement` cases are fed their content UNCONDITIONALLY.** A clef has no default type to be
///   absent from, so `combine(_ element:)` now feeds the identity of a clef, barline, dynamic, fermata, breath,
///   harmony, sticking, expression, spanner and measure repeat rather than a bare case tag. Still byte-free for
///   the existing chain, whose fixture holds none of those elements.
extension FNV1a {
    mutating func combineFlags(_ measure: Measure) {
        if measure.lineBreak { combine(21) }
        if measure.pageBreak { combine(22) }
        if measure.sectionBreak { combine(23) }
        if measure.startRepeat { combine(24) }
        if let count = measure.endRepeatCount {
            combine(25)
            combine(count)
        }
        if let count = measure.measureRepeatCount {
            combine(26)
            combine(count)
        }
        if !measure.markers.isEmpty {
            combine(27)
            combine(measure.markers.count)
            for marker in measure.markers {
                combine(marker.kind.rawValue)
                combine(marker.label)
                combine(marker.text)
            }
        }
        if !measure.jumps.isEmpty {
            combine(28)
            combine(measure.jumps.count)
            for jump in measure.jumps {
                combine(jump.jumpTo)
                combine(jump.playUntil)
                combine(jump.continueAt)
                combine(jump.playRepeats)
                combine(jump.text)
            }
        }
    }

    /// Every field an edit can change. `preservedMarkup` is deliberately out:
    /// it is source fidelity, not model state, and no edit command reaches it.
    mutating func combine(_ ornament: ChordOrnament) {
        combine(ornament.kind.mscxToken)
        combine(ornament.intervalAbove?.mscxToken)
        combine(ornament.intervalBelow?.mscxToken)
        combine(ornament.showAccidental?.rawValue ?? -1)
        combine(ornament.showCueNote?.rawValue)
        combine(ornament.ornamentStyle?.rawValue)
        combine(ornament.accidentalAbove?.rawValue)
        combine(ornament.accidentalBelow?.rawValue)
        combineTristate(ornament.startOnUpperNote)
        combineTristate(ornament.plays)
        combineOccupied(ornament.elementProperties, visibleTag: 34, colorTag: 35)
    }

    /// `nil` / `false` / `true` as `0` / `1` / `2`. A plain `combine(_ flag:)`
    /// would collapse "absent" onto "false", and these two `Bool?`s mean
    /// different things: absent is "MuseScore wrote no tag", false is "the
    /// author turned it off".
    mutating func combineTristate(_ flag: Bool?) {
        guard let flag else {
            combine(0)
            return
        }
        combine(flag ? 2 : 1)
    }

    /// `preservedMarkup` stays out, as it does for `ChordOrnament`: it is
    /// source fidelity, not model state.
    mutating func combine(_ fingering: Fingering) {
        combine(fingering.text)
        combine(fingering.role.mscxToken)
        combineOccupied(fingering.elementProperties, visibleTag: 37, colorTag: 38)
    }

    /// Every modeled symbol field an edit can change. `preservedMarkup` stays
    /// out because it is source fidelity rather than model state.
    mutating func combine(_ symbol: EngravingSymbol) {
        combine(symbol.name)
        combine(symbol.scoreFont)
        combinePresence(symbol.size)
        combinePresence(symbol.angle)
        combineOccupied(symbol.elementProperties, visibleTag: 47, colorTag: 48)
    }

    /// Every case that carries *timing* — i.e. anything that changes how much tick budget an element occupies, or
    /// where the cursor lands afterward — is listed explicitly. `.chord` carries its own duration (rests are chords
    /// with no notes, per `VoiceElement`'s doc comment) and `.locationShift` carries a tick-offset delta that moves
    /// the cursor for whatever attaches next; both must be distinguishable from each other and from the non-timed
    /// markers below, or two scores that differ only in a rest's length or a cursor jog could hash equally.
    ///
    /// `.keySignature` and `.timeSignature` occupy no tick budget either, but they DO carry content M3's signature
    /// commands write — the whole point of `.setKeySignature` / `.setTimeSignature` is to change what a bar
    /// declares — so both are fed their own fields rather than a tag. Without that, changing the key of a bar of
    /// rests (nothing to re-spell) would move nothing this walk can see, and a mirror that failed to apply the same
    /// change would still agree. `showCourtesy` and `visible` ride along because the replace path in
    /// `SetKeySignature` does not preserve them.
    ///
    /// The remaining cases occupy no tick budget of their own — they are markers attached at the current cursor
    /// position — but they now feed their own identity rather than a bare discriminant tag, per the edit-command
    /// parity project (spec 2026-09-02 §2.5): the `combine(_ clef:)` / `combine(_ barLine:)` /
    /// `combine(_ dynamic:)` / `combine(_ fermata:)` / `combine(_ breath:)` / `combine(_ harmony:)` /
    /// `combine(_ sticking:)` / `combine(_ expression:)` / `combine(_ capo:)` / `combine(_ tunings:)` /
    /// `combine(_ ambitus:)` / `combine(_ spanner:)` / `combine(_ repeat:)` overloads below are what this switch
    /// calls into.
    ///
    /// This switch lives here rather than in `ScoreFingerprintHasher.swift` because every overload it
    /// dispatches to is in this file, and because that one was at the `file_length` limit — a new
    /// `VoiceElement` case cost two lines there and none here.
    mutating func combine(_ element: VoiceElement) {
        switch element {
        case let .chord(chord):
            combine(0)
            combine(chord)
        case let .keySignature(key):
            combine(1)
            combine(key.concertKey)
            combine(key.showCourtesy)
            combine(key.visible)
        case let .timeSignature(time):
            combine(2)
            combine(time.numerator)
            combine(time.denominator)
            combine(time.showCourtesy)
            combine(time.visible)
        case let .clef(clef):
            combine(3)
            combine(clef)
        case let .barLine(barLine):
            combine(4)
            combine(barLine)
        case let .dynamic(dynamic):
            combine(5)
            combine(dynamic)
        case let .spanner(spanner):
            combine(6)
            combine(spanner)
        case let .measureRepeat(`repeat`):
            combine(7)
            combine(`repeat`)
        case let .fermata(fermata):
            combine(8)
            combine(fermata)
        case let .breath(breath):
            combine(9)
            combine(breath)
        case let .harmony(harmony):
            combine(10)
            combine(harmony)
        case let .locationShift(delta):
            combine(11)
            combine(delta)
        case let .sticking(sticking):
            combine(12)
            combine(sticking)
        case let .expression(expression):
            combine(13)
            combine(expression)
        case let .capo(capo):
            combine(14)
            combine(capo)
        case let .stringTunings(tunings):
            combine(15)
            combine(tunings)
        case let .ambitus(ambitus):
            combine(16)
            combine(ambitus)
        case .preserved:
            // Source-only XML is outside the semantic edit fingerprint.
            break
        }
    }

    mutating func combine(_ clef: Clef) {
        combine(clef.concertClefType)
        combine(clef.transposingClefType)
        combine(clef.visible)
    }

    mutating func combine(_ barLine: BarLine) {
        combine(barLine.subtype)
        combine(barLine.visible)
    }

    mutating func combine(_ dynamic: Dynamic) {
        combine(dynamic.subtype)
        combine(dynamic.velocity)
        combine(dynamic.visible)
    }

    mutating func combine(_ fermata: Fermata) {
        combine(fermata.subtype)
        combine(fermata.timeStretch)
        combine(fermata.visible)
    }

    mutating func combine(_ breath: Breath) {
        switch breath.kind {
        case let .breathMark(style):
            combine(0)
            combine(style.rawValue)
        case let .caesura(style):
            combine(1)
            combine(style.rawValue)
        }
        combine(breath.pause)
        combine(breath.visible)
    }

    mutating func combine(_ harmony: Harmony) {
        combine(harmony.name)
        combine(harmony.harmonyType.rawValue)
        combinePresence(harmony.rootTpc)
        combinePresence(harmony.bassTpc)
        combine(harmony.visible)
    }

    mutating func combine(_ sticking: Sticking) {
        combine(sticking.text)
        combineOccupied(sticking.elementProperties, visibleTag: 39, colorTag: 40)
    }

    mutating func combine(_ expression: ExpressionText) {
        combine(expression.text)
        combinePresence(expression.snapToDynamics.map { $0 ? 1 : 0 })
        combineOccupied(expression.elementProperties, visibleTag: 41, colorTag: 42)
    }

    mutating func combine(_ capo: Capo) {
        combine(capo.isActive)
        combine(capo.fretPosition)
        combine(capo.generatesText)
        combinePresence(capo.transposeMode?.mscxOrdinal)
        combine(capo.ignoredStrings.count)
        for string in capo.ignoredStrings.sorted() {
            combine(string)
        }
        combine(capo.text)
        combineOccupied(capo.elementProperties, visibleTag: 49, colorTag: 50)
    }

    mutating func combine(_ tunings: StringTunings) {
        combine(tunings.preset)
        combine(tunings.visibleStrings.count)
        for string in tunings.visibleStrings {
            combine(string)
        }
        // `StringData` is deliberately omitted, matching `Instrument`: this
        // is a semantic-edit fingerprint rather than a fidelity hash.
        combine(tunings.text)
        combineOccupied(tunings.elementProperties, visibleTag: 51, colorTag: 52)
    }

    /// Every modeled ambitus field an edit can change. `preservedMarkup` stays
    /// out because it is source fidelity rather than model state.
    mutating func combine(_ ambitus: Ambitus) {
        combine(ambitus.topPitch)
        combine(ambitus.topTpc)
        combine(ambitus.bottomPitch)
        combine(ambitus.bottomTpc)
        combine(ambitus.noteHeadGroup)
        combinePresence(ambitus.noteHeadType?.mscxOrdinal)
        combinePresence(ambitus.mirror?.mscxOrdinal)
        combine(ambitus.hasLine)
        combinePresence(ambitus.lineWidth)
        combine(ambitus.topAccidental)
        combine(ambitus.bottomAccidental)
        combineOccupied(ambitus.elementProperties, visibleTag: 53, colorTag: 54)
    }

    mutating func combine(_ repeat: MeasureRepeat) {
        combine(`repeat`.numMeasures)
        combine(`repeat`.duration)
    }

    mutating func combine(_ spanner: Spanner) {
        combine(spanner.kind.rawValue)
        combine(spanner.rawType)
        combine(spanner.nextMeasuresOffset)
        combine(spanner.nextFractionsOffset)
        combine(spanner.voltaEndings.count)
        for ending in spanner.voltaEndings {
            combine(ending)
        }
        combine(spanner.beginText)
        combine(spanner.placement?.rawValue)
        combinePresence(spanner.hairpin?.subtype.rawValue)
        combinePresence(spanner.hairpin?.veloChange)
        combine(spanner.hairpin?.veloChangeMethod.rawValue)
        combine(spanner.ottava?.subtype.rawValue)
        combinePresence(spanner.ottava?.numbersOnly.map { $0 ? 1 : 0 })
        combine(spanner.vibrato?.type.rawValue)
        combine(spanner.trill?.type.rawValue)
        combine(spanner.visible)
    }

    /// Explicit 0/1 presence byte for an unbounded `Int?` — the `combine(_ fraction:)` / `combine(_ address:)`
    /// rule, restated for the TPCs and velocities above, whose `-1` is a real value.
    mutating func combinePresence(_ value: Int?) {
        guard let value else {
            combine(0)
            return
        }
        combine(1)
        combine(value)
    }

    /// Explicit 0/1 presence byte for a `Double?`, keeping an absent hook
    /// length distinct from every possible IEEE 754 bit pattern.
    mutating func combinePresence(_ value: Double?) {
        guard let value else {
            combine(0)
            return
        }
        combine(1)
        combine(value)
    }
}
