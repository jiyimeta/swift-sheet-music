import SheetMusicFoundation

/// A deterministic 64-bit digest of everything score *editing* can change, for comparing two copies of a score that
/// live in different processes or — on Android — in two separately linked images of this module.
///
/// Deliberately not built on `Hashable` / `Hasher`: those are seeded per process, so two images would disagree about
/// identical scores. FNV-1a is fixed by its constants and gives the same answer everywhere.
///
/// Scope is the mutable musical content — element kind, timing, pitch, spelling, ties, tuplet ratios. Everything
/// else is out, which keeps the walk cheap, but "engraving trivia" undersells how much that actually excludes —
/// spelled out here so the next person adding an intent knows exactly what this walk is blind to, rather than
/// discovering it by omission:
///
/// - Not covered on `Chord`: `elementProperties` (both `visible` and `color`) — display-only, and no edit command
///   in this package sets either half of it.
/// - Not covered on `Note`: `elementProperties.color` — the other half, `visible`, is covered via `Note.visible`
///   below; `color` is author-supplied paint no edit command in this package sets.
/// - Not covered within the nested types the walk now recurses into: `Arpeggio.elementProperties`,
///   `Lyric.elementProperties`, and `ChordLine.elementProperties` (visibility/color on those attachments, same
///   reasoning as the two bullets above), plus `Lyric.properties` (text positioning/formatting) and
///   `ChordLine.path` (hand-drawn Bezier control points) — all display-only, none of it set by any edit command
///   in this package today.
/// - Not covered at all: every `Measure` property (`startRepeat`, `endRepeatCount`, `measureRepeatCount`,
///   `markers`, `jumps`, `lineBreak`, `pageBreak`, `sectionBreak`, `actualLength`, `irregular`),
///   `Staff.defaultClefType`, and `Score.systemMeasures`.
/// - The walk's own shape: it emits a flat sequence of staff blocks with no part/staff-count delimiter, so two
///   scores whose staves are grouped into parts differently — but which total the same number of staves — hash
///   identically.
///
/// None of the above is reachable by any `EditIntent` this package accepts today, so the walk's contract still
/// holds: a difference it cannot see is a missed detection, never a false alarm. But that contract is only as good
/// as this list — the next edit command that touches one of these fields must add it here, not assume it already
/// is.
extension Score {
    public var stableFingerprint: Int64 {
        var hash = FNV1a()
        for part in parts {
            for staff in part.staves {
                hash.combine(staff.measures.count)
                for measure in staff.measures {
                    hash.combine(measure.voices.count)
                    for voice in measure.voices {
                        hash.combine(voice.elements.count)
                        for element in voice.elements {
                            hash.combine(element)
                        }
                        hash.combine(voice.tuplets.count)
                        for tuplet in voice.tuplets {
                            hash.combine(tuplet.actualNotes)
                            hash.combine(tuplet.normalNotes)
                            hash.combine(tuplet.startIndex)
                            hash.combine(tuplet.endIndex)
                        }
                    }
                }
            }
        }
        return Int64(bitPattern: hash.value)
    }
}

/// FNV-1a, 64-bit. Fixed constants, no seed — that is the whole point.
private struct FNV1a {
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
        combine(chord.tremolo)
        combine(chord.chordLines.count)
        for chordLine in chord.chordLines {
            combine(chordLine)
        }
        combine(chord.stemVisible)
        combine(chord.beamVisible)
    }

    /// Every case that carries *timing* — i.e. anything that changes how much tick budget an element occupies, or
    /// where the cursor lands afterward — is listed explicitly. `.chord` carries its own duration (rests are chords
    /// with no notes, per `VoiceElement`'s doc comment) and `.locationShift` carries a tick-offset delta that moves
    /// the cursor for whatever attaches next; both must be distinguishable from each other and from the non-timed
    /// markers below, or two scores that differ only in a rest's length or a cursor jog could hash equally.
    ///
    /// The remaining cases occupy no tick budget of their own — they are markers attached at the current cursor
    /// position — so a discriminant tag is enough; their own field content (e.g. a clef's type, a dynamic's marking)
    /// is display/notation-only and none of it is mutated by any edit command in this package today. Should that
    /// change, the new field belongs in this walk, not folded into the tag.
    mutating func combine(_ element: VoiceElement) {
        switch element {
        case let .chord(chord):
            combine(0)
            combine(chord)
        case .keySignature: combine(1)
        case .timeSignature: combine(2)
        case .clef: combine(3)
        case .barLine: combine(4)
        case .dynamic: combine(5)
        case .spanner: combine(6)
        case .measureRepeat: combine(7)
        case .fermata: combine(8)
        case .breath: combine(9)
        case .harmony: combine(10)
        case let .locationShift(delta):
            combine(11)
            combine(delta)
        }
    }
}
