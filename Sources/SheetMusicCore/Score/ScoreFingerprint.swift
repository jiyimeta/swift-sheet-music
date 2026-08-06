import Foundation

/// A deterministic 64-bit digest of everything score *editing* can change, for comparing two copies of a score that
/// live in different processes or — on Android — in two separately linked images of this module.
///
/// Deliberately not built on `Hashable` / `Hasher`: those are seeded per process, so two images would disagree about
/// identical scores. FNV-1a is fixed by its constants and gives the same answer everywhere.
///
/// Scope is the mutable musical content — element kind, timing, pitch, spelling, ties, tuplet ratios. Engraving
/// trivia the edit commands never touch is out, which keeps the walk cheap. A difference this walk cannot see is a
/// missed detection, never a false alarm.
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

    /// Feeds a string's UTF-8 bytes, length-prefixed so two adjacent fields can never blur into each other (e.g. an
    /// empty string followed by "x" hashing the same as "x" followed by an empty string).
    mutating func combine(_ string: String) {
        combine(string.utf8.count)
        for byte in string.utf8 {
            combine(byte)
        }
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

    mutating func combine(_ note: Note) {
        combine(note.pitch)
        combine(note.tpc)
        combine(note.accidental)
        combine(note.tieForward ?? -1)
        combine(note.tieBack ?? -1)
    }

    mutating func combine(_ chord: Chord) {
        combine(chord.duration)
        combine(chord.notes.count)
        for note in chord.notes {
            combine(note)
        }
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
