import SheetMusicFoundation

/// FNV-1a, 64-bit. Fixed constants, no seed — that is the whole point.
///
/// Split out of `ScoreFingerprint.swift` when the walk outgrew the file-length budget; the two are one unit and the
/// contract that governs both — what the walk covers and what it is blind to — is stated over there, on
/// `Score.stableFingerprint`. Internal rather than `private` only because the type now spans two files: nothing
/// outside this module may see it.
struct FNV1a {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func combine(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 0x0000_0100_0000_01B3
    }

    mutating func combine(_ int: Int) {
        var bits = UInt64(bitPattern: Int64(int))
        for _ in 0 ..< 8 {
            combine(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }

    mutating func combine(_ flag: Bool) {
        combine(flag ? 1 : 0)
    }

    /// Feeds a `Double`'s raw bit pattern, 8 bytes, the same shape as `combine(_ int:)`.
    mutating func combine(_ double: Double) {
        var bits = double.bitPattern
        for _ in 0 ..< 8 {
            combine(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }

    /// Feeds a string's UTF-8 bytes, length-prefixed so two adjacent fields can never blur into each other (e.g. an
    /// empty string followed by "x" hashing the same as "x" followed by an empty string).
    mutating func combine(_ string: String) {
        combine(string.utf8.count)
        for byte in string.utf8 {
            combine(byte)
        }
    }

    /// `nil` gets the `-1` sentinel `combine(_ accidental:)` already established: a real string's length-prefixed
    /// encoding always starts with a non-negative count, which can never equal `-1`'s bit pattern.
    mutating func combine(_ string: String?) {
        guard let string else {
            combine(-1)
            return
        }
        combine(string)
    }

    mutating func combine(_ fraction: Fraction) {
        combine(fraction.numerator)
        combine(fraction.denominator)
    }

    /// Explicit 0/1 presence byte rather than a value-encoded sentinel, for the reason `combine(_ arpeggio:)`
    /// spells out: `Fraction.numerator` is a plain `Int` with no guaranteed range, so a `-1` sentinel could be
    /// mistaken for the first half of a real `Fraction(-1, d)`. The `nil` case is the `0` marker and nothing else,
    /// which no present case (always `1` followed by the fraction's own two fields) can produce.
    mutating func combine(_ fraction: Fraction?) {
        guard let fraction else {
            combine(0)
            return
        }
        combine(1)
        combine(fraction)
    }

    /// Same presence-byte shape as `combine(_ fraction:)` — both of a `StaffAddress`'s fields are unbounded `Int`s.
    mutating func combine(_ address: StaffAddress?) {
        guard let address else {
            combine(0)
            return
        }
        combine(1)
        combine(address.partIndex)
        combine(address.staffIndexInPart)
    }

    mutating func combine(_ duration: NoteDuration) {
        switch duration {
        case .whole: combine(1)
        case .half: combine(2)
        case .quarter: combine(3)
        case .eighth: combine(4)
        case .sixteenth: combine(5)
        case .thirtySecond: combine(6)
        case .sixtyFourth: combine(7)
        case .oneTwentyEighth: combine(8)
        case .twoFiftySixth: combine(9)
        case .measure: combine(10)
        case let .fraction(f):
            combine(11)
            combine(f)
        }
    }

    /// `nil` gets a sentinel distinct from every real spelling: an `Accidental` is a non-empty raw-value string, so
    /// its length-prefixed encoding can never collide with the `-1` sentinel `combine(_ int:)` produces.
    mutating func combine(_ accidental: Accidental?) {
        guard let accidental else {
            combine(-1)
            return
        }
        combine(accidental.rawValue)
    }

    /// `nil` sentinel matches `combine(_ accidental:)`: `style`'s tag below is `0...4`, never `-1`.
    mutating func combine(_ glissando: Glissando?) {
        guard let glissando else {
            combine(-1)
            return
        }
        switch glissando.style {
        case .chromatic: combine(0)
        case .diatonic: combine(1)
        case .whiteKeys: combine(2)
        case .blackKeys: combine(3)
        case .portamento: combine(4)
        }
        switch glissando.visualType {
        case .straight: combine(0)
        case .wavy: combine(1)
        }
        combine(glissando.easeIn)
        combine(glissando.easeOut)
        combine(glissando.text)
    }

    mutating func combine(_ note: Note) {
        combine(note.pitch)
        combine(note.tpc)
        combine(note.accidental)
        combine(note.tieForward ?? -1)
        combine(note.tieBack ?? -1)
        combine(note.accidentalBracket.rawValue)
        combine(note.accidentalRole.rawValue)
        combine(note.glissando)
        combine(note.headType)
        switch note.parentheses {
        case .none: combine(0)
        case .left: combine(1)
        case .right: combine(2)
        case .both: combine(3)
        }
        combine(note.isSmall)
        combine(note.play)
        combine(note.visible)
        if let color = note.elementProperties.color {
            combine(31)
            combine(color.red)
            combine(color.green)
            combine(color.blue)
            combine(color.alpha)
        }
    }

    /// `Arpeggio.subtype` is a plain `Int` (not an enum), so — unlike `combine(_ accidental:)`'s raw-value string
    /// or `combine(_ tremolo:)`'s raw-value enum — no type guarantees its range; a value-encoded sentinel like
    /// `-1` could alias a malformed-but-real `subtype`. Feed an explicit 0/1 presence byte instead: the `nil`
    /// case is then the single byte `0` and nothing else, which no non-nil case (always `1` followed by more
    /// bytes) can ever produce.
    mutating func combine(_ arpeggio: Arpeggio?) {
        guard let arpeggio else {
            combine(0)
            return
        }
        combine(1)
        combine(arpeggio.subtype)
        combine(arpeggio.timeStretch)
        combine(arpeggio.userLen1)
    }

    mutating func combine(_ lyric: Lyric) {
        combine(lyric.text)
        switch lyric.syllabic {
        case .single: combine(0)
        case .begin: combine(1)
        case .middle: combine(2)
        case .end: combine(3)
        }
        combine(lyric.ticks)
        combine(lyric.verse)
    }

    /// Recurses into the grace chord's own notes (via `combine(_ note:)`) rather than hashing a count, so a
    /// planner that copies the wrong pitch into a grace note — not just the wrong number of them — is caught.
    mutating func combine(_ graceChord: GraceChord) {
        combine(graceChord.graceType.mscxTag)
        combine(graceChord.duration)
        combine(graceChord.notes.count)
        for note in graceChord.notes {
            combine(note)
        }
    }

    mutating func combine(_ articulation: ChordArticulation) {
        switch articulation.kind {
        case .staccato: combine(0)
        case .staccatissimo: combine(1)
        case .tenuto: combine(2)
        case .accent: combine(3)
        case .marcato: combine(4)
        case .accentStaccato: combine(5)
        case .marcatoStaccato: combine(6)
        case let .unknown(subtype):
            combine(7)
            combine(subtype)
        }
        guard let anchor = articulation.anchor else {
            combine(-1)
            return
        }
        switch anchor {
        case .above: combine(0)
        case .below: combine(1)
        }
    }

    /// `nil` sentinel matches `combine(_ accidental:)`: `Tremolo.Subtype`'s raw values are `1...4`, never `-1`.
    mutating func combine(_ tremolo: Tremolo?) {
        guard let tremolo else {
            combine(-1)
            return
        }
        combine(Int(tremolo.subtype.rawValue))
        switch tremolo.span {
        case .single: combine(0)
        case .between: combine(1)
        }
        combine(tremolo.strokeStyle.rawValue)
    }

    /// Covers the chord line's identity and shape (`kind`, the straight/wavy/plays flags, its extent, and which
    /// note it anchors to) but not `path` (hand-drawn Bezier control points) or `elementProperties` — hand-drawn
    /// curve geometry and visibility/color are display-only, in the same spirit as the exclusions this file's doc
    /// comment lists; no edit command in this package sets either.
    mutating func combine(_ chordLine: ChordLine) {
        switch chordLine.kind {
        case .fall: combine(0)
        case .doit: combine(1)
        case .plop: combine(2)
        case .scoop: combine(3)
        }
        combine(chordLine.isStraight)
        combine(chordLine.isWavy)
        combine(chordLine.plays)
        combine(chordLine.lengthX)
        combine(chordLine.lengthY)
        combine(chordLine.noteIndex ?? -1)
    }

    mutating func combine(_ chord: Chord) {
        combine(chord.duration)
        combine(chord.notes.count)
        for note in chord.notes {
            combine(note)
        }
        combine(chord.arpeggio)
        combine(chord.lyrics.count)
        for lyric in chord.lyrics {
            combine(lyric)
        }
        combine(chord.graceNotesBefore.count)
        for graceChord in chord.graceNotesBefore {
            combine(graceChord)
        }
        combine(chord.graceNotesAfter.count)
        for graceChord in chord.graceNotesAfter {
            combine(graceChord)
        }
        combine(chord.articulations.count)
        for articulation in chord.articulations {
            combine(articulation)
        }
        combineOccupied(chord.ornaments, tag: 33)
        combine(chord.tremolo)
        combine(chord.chordLines.count)
        for chordLine in chord.chordLines {
            combine(chordLine)
        }
        combine(chord.stemVisible)
        combine(chord.beamVisible)
        combineOccupied(chord.spanners, tag: 32)
        combineOccupied(chord.elementProperties, visibleTag: 29, colorTag: 30)
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
    /// parity project (spec 2026-09-02 §2.5): see `ScoreFingerprintHasher+Parity.swift` for the
    /// `combine(_ clef:)` / `combine(_ barLine:)` / `combine(_ dynamic:)` / `combine(_ fermata:)` /
    /// `combine(_ breath:)` / `combine(_ harmony:)` / `combine(_ spanner:)` / `combine(_ repeat:)` overloads this
    /// switch calls into.
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
        case .preserved:
            // Source-only XML is outside the semantic edit fingerprint.
            break
        }
    }

    /// Unlike `combine(_ element: VoiceElement)`'s marker cases, every case here is fed the fields that give the
    /// element its musical identity, not a tag alone. Re-barring MOVES these elements between columns rather than
    /// rewriting them, and a tag alone cannot tell two same-kind elements that swapped bars apart from two that
    /// stayed put — the position and measure index `combineSystemLane` feeds would be identical either way.
    ///
    /// What stays out is the display trivia hanging off each one (`offsetX` / `offsetY`, `properties`,
    /// `elementProperties`, `RehearsalMark.frame`, `InstrumentChange.isUserInitialized`), in the same spirit as this
    /// file's other exclusions: no edit command in this package writes any of it.
    mutating func combine(_ element: SystemElement) {
        switch element {
        case let .tempo(tempo):
            combine(0)
            combine(tempo.beatsPerSecond)
            combine(tempo.beatNote)
            combine(tempo.beatDots)
        case let .rehearsalMark(mark):
            combine(1)
            combine(mark.text)
        case let .staffText(text):
            combine(2)
            combine(text.text)
            combine(text.isSystemText)
        case let .swing(swing):
            combine(3)
            combine(swing.text)
            combine(swing.unit.rawValue)
            combine(swing.ratio)
            combine(swing.isSystemText)
        case let .instrumentChange(change):
            combine(4)
            combine(change.text)
            combine(change.instrument?.id)
        }
    }
}
