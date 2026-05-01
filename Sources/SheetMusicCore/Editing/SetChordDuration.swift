import Foundation

/// Change the duration of a chord, mirroring MuseScore's
/// `Score::changeCRlen` (`engraving/editing/cmd.cpp:1692`):
///
/// **Shorten**: replace the chord's duration; the leftover time
/// becomes a rest (or a sequence of standard rests when the
/// remainder isn't itself a power-of-two duration).
///
/// **Lengthen**: walk forward in the same voice and consume
/// following chord/rest elements until enough time is freed; the
/// last consumed element may be partially consumed, in which case
/// the leftover becomes a rest.
///
/// Out of scope (refused with `invalidEdit`):
/// - the chord is inside a `Tuplet` span
/// - lengthening would cross the measure boundary
/// - lengthening would consume past a non-timed element
///   (clef / key sig / time sig / barline)
/// - lengthening would overlap a tuplet that follows the chord
///
/// The inverse comes from `ReplaceVoiceElements`, which restores
/// the exact prior elements + tuplets list so undo is bit-perfect.
public struct SetChordDuration: EditCommand {
    public let location: VoiceElementID
    public let duration: NoteDuration

    public init(at location: VoiceElementID, duration: NoteDuration) {
        self.location = location
        self.duration = duration
    }

    public var affectedLocation: VoiceElementID { location }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let voice = Self.voice(in: score, at: location),
              voice.elements.indices.contains(location.elementIndex)
        else {
            throw SheetMusicError.invalidEdit(
                reason: "SetChordDuration: location \(location) "
                    + "doesn't resolve to a voice element")
        }
        guard case .chord(var chord)
            = voice.elements[location.elementIndex] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetChordDuration: element at \(location) "
                    + "is not a chord")
        }
        // The chord's tick offset inside the measure — needed so
        // any rest pieces we generate land on natural beat
        // boundaries (mirrors MuseScore's `toRhythmicDurationList`).
        let chordRtick = Self.tickOffset(
            in: voice,
            ofElementAt: location.elementIndex,
            division: score.division)
        // Refuse when the chord sits inside a tuplet.
        if voice.tuplets.contains(where: {
            $0.startIndex <= location.elementIndex
                && location.elementIndex <= $0.endIndex
        }) {
            throw SheetMusicError.invalidEdit(
                reason: "SetChordDuration: chord is inside a "
                    + "tuplet (changing duration would invalidate "
                    + "the ratio)")
        }
        let division = score.division
        let srcTicks = chord.duration.ticks(division: division)
        let dstTicks = duration.ticks(division: division)
        if srcTicks == dstTicks {
            // Idempotent — return another SetChordDuration with the
            // current value as a do-nothing inverse.
            return SetChordDuration(at: location, duration: duration)
        }
        var newElements = voice.elements
        let chordIdx = location.elementIndex
        if dstTicks < srcTicks {
            // Shorten: replace the chord and back-fill the leftover
            // with rests aligned to natural beat boundaries.
            chord.duration = duration
            newElements[chordIdx] = .chord(chord)
            let leftover = srcTicks - dstTicks
            let rests = Self.alignedRests(
                forTicks: leftover,
                rtickStart: chordRtick + dstTicks,
                division: division)
            newElements.insert(contentsOf: rests, at: chordIdx + 1)
        } else {
            // Lengthen: walk forward, swallow following timed
            // elements until we've freed `needed` ticks.
            let needed = dstTicks - srcTicks
            var consumed = 0
            var lastConsumedIdx = chordIdx
            // The overshoot of the last consumed element — i.e. the
            // portion that wasn't actually needed and must be
            // re-inserted as a rest.
            var partial = 0
            for idx in (chordIdx + 1)..<newElements.count {
                let elTicks: Int
                switch newElements[idx] {
                case .chord(let c):
                    elTicks = c.duration.ticks(division: division)
                case .rest(let r):
                    elTicks = r.duration.ticks(division: division)
                default:
                    throw SheetMusicError.invalidEdit(
                        reason: "SetChordDuration: lengthening "
                            + "blocked by non-timed element at "
                            + "index \(idx)")
                }
                // Refuse if this element is inside a tuplet.
                if voice.tuplets.contains(where: {
                    $0.startIndex <= idx && idx <= $0.endIndex
                }) {
                    throw SheetMusicError.invalidEdit(
                        reason: "SetChordDuration: lengthening "
                            + "would overlap a tuplet at index \(idx)")
                }
                if consumed + elTicks <= needed {
                    consumed += elTicks
                    lastConsumedIdx = idx
                    if consumed == needed { break }
                } else {
                    partial = (consumed + elTicks) - needed
                    consumed = needed
                    lastConsumedIdx = idx
                    break
                }
            }
            if consumed < needed {
                throw SheetMusicError.invalidEdit(
                    reason: "SetChordDuration: not enough room "
                        + "in the measure to lengthen "
                        + "(need \(needed) ticks, have \(consumed))")
            }
            // Capture the partially-consumed element's kind BEFORE
            // we remove it. When it's a chord, the overshoot keeps
            // the chord's pitch (rendered as a rhythm-aligned tied
            // chain of clones); when it's a rest, the overshoot
            // stays as rests. Mirrors MuseScore's `makeGap` /
            // `addClone` path (`engraving/editing/cmd.cpp:1411-1433`).
            let lastEl = newElements[lastConsumedIdx]
            chord.duration = duration
            newElements[chordIdx] = .chord(chord)
            newElements.removeSubrange((chordIdx + 1)...lastConsumedIdx)
            if partial > 0 {
                let durations = Self.alignedDurations(
                    forTicks: partial,
                    rtickStart: chordRtick + dstTicks,
                    division: division)
                let pieces: [VoiceElement]
                switch lastEl {
                case .chord(let consumed):
                    pieces = Self.makeChordChain(
                        from: consumed, durations: durations)
                default:
                    pieces = durations.map {
                        .rest(Rest(duration: $0))
                    }
                }
                newElements.insert(
                    contentsOf: pieces, at: chordIdx + 1)
            }
        }
        // Tuplets that lived before `chordIdx` keep their indices
        // unchanged. Tuplets after the modified region need their
        // start/end shifted by the net change in element count
        // (lengthen → some elements removed, possibly some rest
        // inserts; shorten → rest inserts).
        let priorCount = voice.elements.count
        let netDelta = newElements.count - priorCount
        let adjustedTuplets: [Tuplet] = voice.tuplets.map { t in
            if t.startIndex > chordIdx {
                return Tuplet(
                    normalNotes: t.normalNotes,
                    actualNotes: t.actualNotes,
                    startIndex: t.startIndex + netDelta,
                    endIndex: t.endIndex + netDelta)
            }
            return t
        }
        let replace = ReplaceVoiceElements(
            staffIndex: location.staffIndex,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: newElements,
            tuplets: adjustedTuplets)
        return try replace.apply(to: &score)
    }

    private static func voice(
        in score: Score, at id: VoiceElementID
    ) -> Voice? {
        guard score.staves.indices.contains(id.staffIndex) else {
            return nil
        }
        let measures = score.staves[id.staffIndex].measures
        guard measures.indices.contains(id.measureIndex) else {
            return nil
        }
        let voices = measures[id.measureIndex].voices
        guard voices.indices.contains(id.voiceIndex) else { return nil }
        return voices[id.voiceIndex]
    }

    /// Beat-aligned decomposition of a `length`-tick gap starting at
    /// `rtickStart` (offset within its measure). Mirrors MuseScore's
    /// `toRhythmicDurationList` / `populateRhythmicList`
    /// (`durationtype.cpp`): each emitted duration is the largest
    /// power-of-two duration `D` such that `D <= remaining` AND
    /// `currentRtick % D == 0`. That alignment rule makes the
    /// pieces group at natural beat boundaries — e.g. the leftover
    /// of a whole-rest measure shortened to an eighth decomposes
    /// as `eighth + quarter + half`, not `half + quarter + eighth`.
    ///
    /// Residues smaller than a 256th note collapse into a single
    /// `.fraction` duration as a defensive fallback (shouldn't
    /// happen with valid power-of-two source / target durations).
    private static func alignedDurations(
        forTicks length: Int,
        rtickStart: Int,
        division: Int
    ) -> [NoteDuration] {
        var result: [NoteDuration] = []
        var rtick = rtickStart
        var remaining = length
        let candidates: [NoteDuration] = [
            .whole, .half, .quarter, .eighth, .sixteenth,
            .thirtySecond, .sixtyFourth,
            .oneTwentyEighth, .twoFiftySixth,
        ]
        while remaining > 0 {
            var picked: NoteDuration?
            for c in candidates {
                let d = c.ticks(division: division)
                if d > 0 && d <= remaining && rtick % d == 0 {
                    picked = c
                    break
                }
            }
            guard let pick = picked else {
                result.append(.fraction(Fraction(
                    numerator: remaining,
                    denominator: division * 4)))
                break
            }
            result.append(pick)
            let dt = pick.ticks(division: division)
            rtick += dt
            remaining -= dt
        }
        return result
    }

    /// Convenience wrapper over `alignedDurations` that wraps each
    /// duration into a `.rest` element. Used by the shorten path.
    private static func alignedRests(
        forTicks length: Int,
        rtickStart: Int,
        division: Int
    ) -> [VoiceElement] {
        alignedDurations(
            forTicks: length, rtickStart: rtickStart,
            division: division
        ).map { .rest(Rest(duration: $0)) }
    }

    /// Build a tied chain of chord clones from `src`, one per entry
    /// in `durations`. Each clone keeps `src`'s notes (pitch / TPC /
    /// accidental) — only the chord-level `duration` differs.
    /// Internal ties: every clone has `tieForward = 1` on its notes
    /// except the last; every clone has `tieBack = 1` except the
    /// first. The first clone's `tieBack` is cleared (the lengthening
    /// chord that now precedes it has a different pitch); the last
    /// clone's `tieForward` inherits `src`'s outbound tie so a tie
    /// that originally extended past `src` survives.
    /// Lyrics / arpeggio carry only on the first clone.
    private static func makeChordChain(
        from src: Chord, durations: [NoteDuration]
    ) -> [VoiceElement] {
        guard !durations.isEmpty else { return [] }
        var pieces: [VoiceElement] = []
        for (idx, dur) in durations.enumerated() {
            let isFirst = idx == 0
            let isLast = idx == durations.count - 1
            var notes = src.notes
            for ni in notes.indices {
                notes[ni].tieBack = isFirst ? nil : 1
                notes[ni].tieForward = isLast
                    ? src.notes[ni].tieForward
                    : 1
            }
            let cloned = Chord(
                duration: dur,
                notes: notes,
                arpeggio: isFirst ? src.arpeggio : nil,
                lyrics: isFirst ? src.lyrics : [])
            pieces.append(.chord(cloned))
        }
        return pieces
    }

    /// Tick offset of `voice.elements[idx]` from the start of the
    /// measure. Sums the durations of preceding chord/rest elements;
    /// non-timed elements (clef, key sig, ...) don't advance the
    /// cursor.
    private static func tickOffset(
        in voice: Voice, ofElementAt idx: Int, division: Int
    ) -> Int {
        var t = 0
        for i in 0..<min(idx, voice.elements.count) {
            switch voice.elements[i] {
            case .chord(let c):
                t += c.duration.ticks(division: division)
            case .rest(let r):
                t += r.duration.ticks(division: division)
            default:
                continue
            }
        }
        return t
    }
}
