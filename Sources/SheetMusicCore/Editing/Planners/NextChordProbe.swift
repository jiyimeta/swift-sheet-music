import SheetMusicFoundation

/// The two forward lookups the notation commands share, both of them a walk over a voice's TIMED elements.
///
/// They exist because two of this package's notation payloads name their partner by ADJACENCY rather than by a
/// stored reference. A two-note tremolo lives on the first chord of the pair and the follower is "the next chord
/// in the voice" (`Tremolo.swift`; the decoder enforces it in `MSCXDecoder+Voice.resolveTremoloPairs`, the
/// renderer re-finds it in `MidiRenderer+Tremolo.swift`) — MuseScore keeps an explicit `m_chord2` pointer there
/// (`dom/tremolotwochord.cpp`) and this model deliberately does not. A glissando's destination is likewise
/// implicit, "the next chord's note" (`Glissando.swift`).
///
/// So a WRITE has to check what a read would find: a `.between` tremolo with no follower decodes back as no
/// tremolo at all, and a glissando on the last chord draws a line to nowhere.
enum NextChordProbe {
    /// The next timed element (chord or rest) after `location` in the SAME voice of the SAME measure, skipping
    /// every non-timed element between them; `nil` at the end of the measure or when `location` does not resolve.
    ///
    /// In-measure on purpose: a two-note tremolo does not cross a bar line in MuseScore, and neither the decoder's
    /// pairing pass nor the renderer's follower search looks past the voice's element array for one measure.
    ///
    /// Rests answer this too — a rest is a `.chord` with no notes (`VoiceElement.rest(duration:)`) — because the
    /// caller, not the walk, decides whether a rest is an acceptable partner.
    static func nextTimedElement(after location: VoiceElementID, in score: Score) -> VoiceElement? {
        guard let voice = score[voice: VoiceRef(location)],
              voice.elements.indices.contains(location.elementIndex)
        else { return nil }
        for index in (location.elementIndex + 1) ..< voice.elements.count {
            if case .chord = voice.elements[index] { return voice.elements[index] }
        }
        return nil
    }

    /// Whether a SOUNDING chord (one with notes) starts anywhere after `location` in the same voice index of the
    /// same staff, walking on into later measures. What a glissando needs: its destination is the next chord,
    /// wherever that is, and only a chord with notes can receive one.
    ///
    /// A `location` that does not resolve answers `false` rather than searching from a slot that is not there:
    /// "what follows an element the score does not have" has no true answer, and a caller that skipped its own
    /// existence check must not be told a destination exists.
    static func hasFollowingChord(after location: VoiceElementID, in score: Score) -> Bool {
        guard let voice = score[voice: VoiceRef(location)],
              voice.elements.indices.contains(location.elementIndex),
              let staff = score[location.staff]
        else { return false }
        for measureIndex in location.measureIndex ..< staff.measures.count {
            let voices = staff.measures[measureIndex].voices
            guard voices.indices.contains(location.voiceIndex) else { continue }
            let elements = voices[location.voiceIndex].elements
            let start = measureIndex == location.measureIndex ? location.elementIndex + 1 : 0
            guard start <= elements.count else { continue }
            for index in start ..< elements.count {
                if case let .chord(chord) = elements[index], !chord.notes.isEmpty { return true }
            }
        }
        return false
    }
}
