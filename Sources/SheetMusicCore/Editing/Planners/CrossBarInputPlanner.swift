import Foundation

/// Spells a note or a rest that outlasts the bar it starts in as a beat-aligned chain running across the barline —
/// the only way a score can write one.
///
/// Without this the letter keys simply died near a barline. The engine refuses any single-slot lengthening that
/// would cross one (`DurationChangeAlgorithm`: "not enough room in the measure to lengthen"), and input applies the
/// armed length and the note as ONE composite, so that refusal took the note down with it: half armed on the last
/// beat of a 4/4 bar produced nothing at all, with no way to tell the key apart from a dead one. The rest key had
/// the same hole, and this closes it on the same terms.
///
/// Everything is planned against the pre-edit score and emitted as one `ReplaceVoiceElements` per measure, so the
/// whole chain is a single undo step and no half-written intermediate state is ever visible.
public enum CrossBarInputPlanner {
    /// What the chain is made of. A chord is cloned into every piece and tied at each joint — the only way a score
    /// can write one sound across a barline; rests don't tie, so the pieces summing to the length ARE the rest,
    /// which is how every engraver writes one. Everything else about the chain — where it breaks, how each bar's
    /// share is beat-aligned, what it displaces — is the same.
    ///
    /// A whole `Chord` rather than one pitch because this also re-times what is already written: a three-note chord
    /// stretched over a barline has to arrive on the far side as the same three notes, not as its lowest one. The
    /// chord's own `duration` is ignored — the plan decides each piece's length.
    public enum Content {
        case chord(Chord)
        case rest
    }

    public struct Plan {
        public let commands: [any EditCommand]
        /// Slot of the first piece — where the selection lands, since that is where the note you wrote begins.
        public let head: VoiceElementID
        /// Slot of the last piece — where the caret's advance walk starts, so it clears the whole chain rather than
        /// parking inside it.
        public let tail: VoiceElementID
    }

    /// The plan for writing `content` for `duration` at `location`, or nil when there is nothing to plan: it fits
    /// its bar (the ordinary single-slot path owns that), or the chain can't be honored — see `segments` (runs off
    /// the end of the staff) and `splice` (a tuplet in the way).
    public static func plan(
        _ content: Content,
        duration: NoteDuration,
        at location: VoiceElementID,
        in score: Score,
    ) -> Plan? {
        guard let room = room(at: location, in: score) else { return nil }
        let wanted = duration.resolved(in: room.measureDuration).ticks(division: room.division)
        guard room.ticks > 0, wanted > room.ticks else { return nil }
        guard let segments = segments(wanted: wanted, from: location, room: room, content: content) else { return nil }
        return plan(segments: segments, content: content, at: location, room: room)
    }

    /// Whether a note of `duration` written at `location` stays inside its bar — i.e. whether the ordinary
    /// single-slot write can express it at all. Callers that can't cross the barline use this to go inert up front
    /// rather than issue an edit the engine will refuse. True for a location that doesn't resolve: judging that is
    /// the engine's job, and it already refuses.
    public static func fitsInMeasure(_ duration: NoteDuration, at location: VoiceElementID, in score: Score) -> Bool {
        guard let room = room(at: location, in: score) else { return true }
        return duration.resolved(in: room.measureDuration).ticks(division: room.division) <= room.ticks
    }

    // MARK: - How much bar is left

    /// What a note starting at one slot has to work with: the ticks between it and the barline, plus everything
    /// needed to keep measuring in the same terms further down the staff.
    private struct Room {
        let staff: Staff
        let measureDurations: [Fraction]
        let measureDuration: Fraction
        let division: Int
        let rtick: Int
        let ticks: Int
    }

    private static func room(at location: VoiceElementID, in score: Score) -> Room? {
        guard let staff = score[location.staff],
              let voice = voice(in: staff, measureIndex: location.measureIndex, voiceIndex: location.voiceIndex),
              voice.elements.indices.contains(location.elementIndex)
        else { return nil }
        let division = score.division
        let measureDurations = score.effectiveMeasureDurations(
            partIndex: location.staff.partIndex,
            staffIndex: location.staff.staffIndexInPart,
        )
        guard measureDurations.indices.contains(location.measureIndex) else { return nil }
        let measureDuration = measureDurations[location.measureIndex]
        let rtick = tickOffset(in: voice, before: location.elementIndex, in: measureDuration, division: division)
        return Room(
            staff: staff,
            measureDurations: measureDurations,
            measureDuration: measureDuration,
            division: division,
            rtick: rtick,
            ticks: measureDuration.ticks(division: division) - rtick,
        )
    }

    // MARK: - Where the pieces go

    /// One measure's share of the chain: the slot it starts at and the beat-aligned lengths that fill its span.
    private struct Segment {
        let measureIndex: Int
        let startIndex: Int
        /// Tick offset of `startIndex` within its measure — what the beat-alignment rule measures against.
        let startRtick: Int
        let ticks: Int
        let durations: [NoteDuration]
    }

    /// The rest of the current bar, then whole bars, then whatever is left of the last one.
    ///
    /// nil when the chain would run past the end of the staff. Writing the part that fits and dropping the rest
    /// would produce a note of a length nobody asked for, silently — refusing leaves the score alone and keeps the
    /// armed length meaning exactly what it says.
    private static func segments(
        wanted: Int, from location: VoiceElementID, room: Room, content: Content,
    ) -> [Segment]? {
        let restOfBar = Segment(
            measureIndex: location.measureIndex,
            startIndex: location.elementIndex,
            startRtick: room.rtick,
            ticks: room.ticks,
            durations: durations(
                forTicks: room.ticks, rtickStart: room.rtick, inMeasure: location.measureIndex,
                room: room, content: content,
            ),
        )
        var segments = [restOfBar]
        var left = wanted - room.ticks
        var measureIndex = location.measureIndex + 1
        while left > 0 {
            guard room.measureDurations.indices.contains(measureIndex),
                  let voice = voice(in: room.staff, measureIndex: measureIndex, voiceIndex: location.voiceIndex),
                  let startIndex = firstTimedIndex(in: voice)
            else { return nil }
            let ticks = min(left, room.measureDurations[measureIndex].ticks(division: room.division))
            guard ticks > 0 else { return nil }
            segments.append(Segment(
                measureIndex: measureIndex,
                startIndex: startIndex,
                startRtick: 0,
                ticks: ticks,
                durations: durations(
                    forTicks: ticks, rtickStart: 0, inMeasure: measureIndex, room: room, content: content,
                ),
            ))
            left -= ticks
            measureIndex += 1
        }
        guard segments.allSatisfy({ !$0.durations.isEmpty }) else { return nil }
        return segments
    }

    /// One segment's beat-aligned lengths — except that a bar the chain covers end to end is one `.measure` rest,
    /// the same promotion `EditorViewModel.restDuration(_:at:)` applies to a single-slot rest that fills its bar.
    /// A silent bar reads as a measure rest whatever the meter; spelling it `.half` + `.quarter` in 3/4 because it
    /// happens to be a link in a longer chain would be the one place that rule didn't hold. Notes never take it —
    /// `.measure` is a rest's spelling.
    private static func durations(
        forTicks ticks: Int, rtickStart: Int, inMeasure measureIndex: Int, room: Room, content: Content,
    ) -> [NoteDuration] {
        if case .rest = content, rtickStart == 0, room.measureDurations.indices.contains(measureIndex),
           ticks == room.measureDurations[measureIndex].ticks(division: room.division)
        {
            return [.measure]
        }
        return DurationChangeAlgorithm.alignedDurations(
            forTicks: ticks, rtickStart: rtickStart, division: room.division,
        )
    }

    private static func plan(
        segments: [Segment],
        content: Content,
        at location: VoiceElementID,
        room: Room,
    ) -> Plan? {
        let pieceCount = segments.reduce(0) { $0 + $1.durations.count }
        var commands: [any EditCommand] = []
        var written = 0
        for segment in segments {
            guard let voice = voice(
                in: room.staff, measureIndex: segment.measureIndex, voiceIndex: location.voiceIndex,
            ) else { return nil }
            let pieces = segment.durations.enumerated().map { offset, duration in
                piece(
                    duration: duration,
                    content: content,
                    isFirst: written + offset == 0,
                    isLast: written + offset == pieceCount - 1,
                )
            }
            guard let spliced = splice(
                pieces,
                into: voice,
                over: segment,
                measureDuration: room.measureDurations[segment.measureIndex],
                division: room.division,
            ) else { return nil }
            commands.append(ReplaceVoiceElements(
                staff: location.staff,
                measureIndex: segment.measureIndex,
                voiceIndex: location.voiceIndex,
                elements: spliced.elements,
                tuplets: spliced.tuplets,
            ))
            written += segment.durations.count
        }
        guard let first = segments.first, let last = segments.last else { return nil }
        return Plan(
            commands: commands,
            head: VoiceElementID(
                staff: location.staff,
                measureIndex: first.measureIndex,
                voiceIndex: location.voiceIndex,
                elementIndex: first.startIndex,
            ),
            tail: VoiceElementID(
                staff: location.staff,
                measureIndex: last.measureIndex,
                voiceIndex: location.voiceIndex,
                elementIndex: last.startIndex + last.durations.count - 1,
            ),
        )
    }

    // MARK: - Rewriting one measure

    /// `voice`'s elements with `segment`'s span replaced by `pieces`, plus the tuplet list that goes with them.
    ///
    /// nil when the span can't be rewritten: a tuplet overlaps it (member lengths are the tuplet's to decide, and
    /// the engine refuses the equivalent single-slot edit for the same reason), or the measure holds less music
    /// than the segment claims.
    private static func splice(
        _ pieces: [VoiceElement],
        into voice: Voice,
        over segment: Segment,
        measureDuration: Fraction,
        division: Int,
    ) -> (elements: [VoiceElement], tuplets: [Tuplet])? {
        let elements = voice.elements
        guard elements.indices.contains(segment.startIndex) else { return nil }
        var carried: [VoiceElement] = []
        var leftover: [VoiceElement] = []
        var consumed = 0
        var index = segment.startIndex
        while consumed < segment.ticks, index < elements.count {
            guard let ticks = elements[index].tickCount(division: division, in: measureDuration) else {
                // A chord symbol, a dynamic, a mid-bar clef: nothing is dropped, it just collapses to the end of
                // the span the new note now covers — there is no tick position left inside it to hold.
                carried.append(elements[index])
                index += 1
                continue
            }
            if consumed + ticks <= segment.ticks {
                consumed += ticks
            } else {
                leftover = overshoot(
                    of: elements[index],
                    ticks: consumed + ticks - segment.ticks,
                    rtickStart: segment.startRtick + segment.ticks,
                    division: division,
                )
                consumed = segment.ticks
            }
            index += 1
        }
        guard consumed == segment.ticks else { return nil }
        let consumedEnd = index - 1
        guard !voice.tuplets.contains(where: { $0.startIndex <= consumedEnd && segment.startIndex <= $0.endIndex })
        else { return nil }

        var newElements = Array(elements[..<segment.startIndex])
        newElements.append(contentsOf: pieces)
        newElements.append(contentsOf: carried)
        newElements.append(contentsOf: leftover)
        newElements.append(contentsOf: elements[index...])
        let delta = newElements.count - elements.count
        let tuplets = voice.tuplets.map { tuplet in
            guard tuplet.startIndex > consumedEnd else { return tuplet }
            return Tuplet(
                normalNotes: tuplet.normalNotes,
                actualNotes: tuplet.actualNotes,
                startIndex: tuplet.startIndex + delta,
                endIndex: tuplet.endIndex + delta,
            )
        }
        return (newElements, tuplets)
    }

    /// What is left of an element the chain only partly covers. A chord keeps its pitch as a tied chain, the way
    /// `DurationChangeAlgorithm` surfaces the same overshoot when a length change eats into the next note; a rest
    /// just becomes shorter rests.
    private static func overshoot(
        of element: VoiceElement,
        ticks: Int,
        rtickStart: Int,
        division: Int,
    ) -> [VoiceElement] {
        let durations = DurationChangeAlgorithm.alignedDurations(
            forTicks: ticks, rtickStart: rtickStart, division: division,
        )
        guard case let .chord(chord) = element, !chord.notes.isEmpty else {
            return durations.map { .rest(duration: $0) }
        }
        return DurationChangeAlgorithm.makeChordChain(from: chord, durations: durations)
    }

    /// One link of the chain: tied at every interior joint, with the chord's ties at the two ENDS left as its own —
    /// a note tied in from before is still tied in, and one tied onward still is.
    ///
    /// The head keeps the source chord entire; the continuations are bare noteheads. That is where an engraver puts
    /// the marks — an arpeggio, a lyric, a staccato dot, a grace note belong to the sound, and a tied group is one
    /// sound, so they sit on the notehead it starts from and nowhere else. It also means re-timing a decorated chord
    /// across a barline loses nothing, which matters because the same edit one beat earlier (`SetChordDuration`,
    /// in-bar) keeps everything.
    private static func piece(
        duration: NoteDuration, content: Content, isFirst: Bool, isLast: Bool,
    ) -> VoiceElement {
        guard case let .chord(source) = content else { return .rest(duration: duration) }
        var notes = source.notes
        for index in notes.indices {
            notes[index].tieBack = isFirst ? source.notes[index].tieBack : 1
            notes[index].tieForward = isLast ? source.notes[index].tieForward : 1
        }
        guard isFirst else {
            return .chord(Chord(
                duration: duration, notes: notes, graceNotesAfter: isLast ? source.graceNotesAfter : [],
            ))
        }
        var head = source
        head.duration = duration
        head.notes = notes
        // Grace notes AFTER the chord lead into whatever follows the sound, so they belong on its last piece, not
        // its first — the one case the head doesn't keep.
        head.graceNotesAfter = isLast ? source.graceNotesAfter : []
        return .chord(head)
    }

    // MARK: - Lookups

    private static func voice(in staff: Staff, measureIndex: Int, voiceIndex: Int) -> Voice? {
        guard staff.measures.indices.contains(measureIndex) else { return nil }
        let voices = staff.measures[measureIndex].voices
        guard voices.indices.contains(voiceIndex) else { return nil }
        return voices[voiceIndex]
    }

    /// The first chord/rest slot in a voice — where a bar's share of the chain starts, skipping the clef / key /
    /// time signature a measure may open with.
    private static func firstTimedIndex(in voice: Voice) -> Int? {
        voice.elements.firstIndex { if case .chord = $0 { true } else { false } }
    }

    private static func tickOffset(
        in voice: Voice, before index: Int, in measureDuration: Fraction, division: Int,
    ) -> Int {
        voice.elements.prefix(index).reduce(0) {
            $0 + ($1.tickCount(division: division, in: measureDuration) ?? 0)
        }
    }
}
