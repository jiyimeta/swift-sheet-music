import SheetMusicFoundation

/// Why a bar is left exactly as it was (design §4.7): converting it would change what plays, lose a marking, or move
/// one to another tick. The host reports how many bars were left and which is first; the reason is for tests and
/// diagnostics.
enum RevoiceKeepReason: Equatable, Sendable {
    /// A shape the writer does not take on.
    case unsupported
    /// A tie or tremolo whose length is audible could not keep it (§4.4).
    case audibleLength
    /// Tuplets that cannot be carried or merged member by member (§4.5).
    case tuplets
    /// A chord-level marking that changes how its notes play — a tremolo or an arpeggio — cannot travel (§4.5).
    case markings
    /// A voice-stream annotation would land inside a chord rather than at an onset.
    case annotationPlacement
    /// A dynamic or hairpin assigned to its own voice only would govern other notes (§4.5).
    case voiceOnlyDynamics
    /// The meter cannot spell what the bar needs.
    case unspellable
}

/// What a rewritten bar writes into one voice: the whole voice, as `ReplaceVoiceElements` takes it.
struct RevoiceVoiceWrite: Equatable, Sendable {
    let voiceIndex: Int
    let slots: [VoiceSlot]
    let tupletSlots: [TupletSlot]
}

/// The decision for one bar.
enum RevoiceBarPlan: Equatable, Sendable {
    /// Already in the target form (design §4.6), or a measure repeat: not touched at all, not even re-spelled.
    case untouched
    /// Converting it would break one of the design's anti-goals; it stays as it was (§4.7).
    case leftAsWritten(RevoiceKeepReason)
    /// Write these voices, then leave the bar with `voiceCountAfter` voices — creating the ones a write targets that
    /// the bar does not have yet, and removing every voice from the last down to that count. The list of writes may
    /// be empty (`.rewrite([], voiceCountAfter:)` only removes voices), but the effect never is: a bar that would
    /// change nothing is `.untouched`.
    case rewrite([RevoiceVoiceWrite], voiceCountAfter: Int)
}

/// Decides, per bar, whether `RevoiceDrumStaff` leaves it alone, leaves it as written, or rewrites it, and writes the
/// voices of a rewritten one.
enum RevoiceBarPlanner {
    static func plan(_ bar: RevoiceBar, voiceForPitch: [Int: Int], policy: RhythmSpellingPolicy) -> RevoiceBarPlan {
        if bar.isMeasureRepeat { return .untouched }
        let targetCount = targetVoiceCount(voiceForPitch)
        guard isInTargetVoices(bar, voiceForPitch: voiceForPitch) else { return .leftAsWritten(.unsupported) }
        guard bar.voices.count > targetCount else { return .untouched }
        // All in place, with voices beyond the target's count: a rest-only voice 2 on a one-voice chart, as MusicXML
        // imports often carry. Removing it is the whole rewrite (§4.6).
        guard bar.voices[targetCount...].allSatisfy(holdsOnlyRests) else { return .leftAsWritten(.unsupported) }
        return .rewrite([], voiceCountAfter: targetCount)
    }

    /// How many voices the target form has: one more than the highest voice the mapping names, at least one.
    static func targetVoiceCount(_ voiceForPitch: [Int: Int]) -> Int {
        max(1, (voiceForPitch.values.max() ?? 0) + 1)
    }

    /// The voice a note of `pitch` belongs in. A pitch the mapping does not name goes to voice 0 (design §7).
    static func targetVoice(ofPitch pitch: Int, in voiceForPitch: [Int: Int]) -> Int {
        voiceForPitch[pitch] ?? 0
    }

    /// The voice a grace chord belongs in: the one its notes share, or voice 0 when they map to different voices —
    /// a flam on the snare stays with the snare (design §4.5).
    static func targetVoice(of grace: GraceChord, in voiceForPitch: [Int: Int]) -> Int {
        let voices = Set(grace.notes.map { targetVoice(ofPitch: $0.pitch, in: voiceForPitch) })
        guard voices.count == 1, let only = voices.first else { return 0 }
        return only
    }

    /// Every note of the bar sits in its target voice (design §4.6), grace notes included: each grace chord belongs
    /// in the voice of the chord that carries it.
    static func isInTargetVoices(_ bar: RevoiceBar, voiceForPitch: [Int: Int]) -> Bool {
        let notesInPlace = bar.hits.allSatisfy { hit in
            targetVoice(ofPitch: hit.pitch, in: voiceForPitch) == hit.source.voiceIndex
        }
        return notesInPlace && bar.chords.allSatisfy { source in
            (source.chord.graceNotesBefore.values + source.chord.graceNotesAfter.values).allSatisfy { grace in
                targetVoice(of: grace, in: voiceForPitch) == source.ref.voiceIndex
            }
        }
    }

    /// The voice holds nothing a removal would drop: no element but rests, and each rest bare — equal to a plain
    /// rest of its duration once its `elementProperties` (visibility, color, offset, placement — none a marking) are
    /// set aside. A rest carrying anything else — an articulation, an ornament, a tremolo, an arpeggio, a lyric, a
    /// grace, a chord-anchored spanner, preserved markup — leaves its bar as written rather than losing it with the
    /// voice.
    static func holdsOnlyRests(_ voice: Voice) -> Bool {
        voice.elements.allSatisfy { element in
            guard case let .chord(chord) = element, chord.notes.isEmpty else { return false }
            var bare = Chord(duration: chord.duration, notes: [])
            bare.elementProperties = chord.elementProperties
            return chord == bare
        }
    }
}
