import SheetMusicFoundation

/// The material a `DuplicateRange` copies: the range's chords and rests plus the non-timed elements standing
/// among them, grouped by the voice they live in and stamped with the absolute tick each one starts at.
///
/// Chords and rests are resolved through `Score.voiceElements(in:)` so the source is exactly what every other
/// range command acts on — one resolution rule for the whole family, and a range that names two staves or is
/// given end-first behaves here as it does there. That call filters on `case .chord`, so the non-timed elements
/// are gathered by a second walk of the same measures (`untimedElements(for:key:geometry:durations:score:
/// rangeStart:rangeEnd:)`) and merged back in at their own ticks.
///
/// Which non-timed kinds travel is decided by what MuseScore's PASTE accepts, not by what its copy writes: the
/// clipboard payload is every non-generated element of every in-range segment (`twrite.cpp:3520-3617`), but the
/// read side handles only clef (`read460.cpp:704-715`), breath (`717-728`) and the annotation list (`664-703`),
/// and silently drops key signature, time signature, barline and rehearsal mark (`739-744`). Carrying the
/// dropped kinds would make a duplicate state something a MuseScore paste never states.
///
/// A range that covers a tuplet only partially cannot be copied at all: `init?(range:in:)` throws
/// `.insideTuplet` rather than producing a `Stream` whose bracket silently dropped its members.
struct RangeCopySource {
    /// One copied element: where it starts on its staff's absolute tick axis, how long it is THERE (zero for a
    /// non-timed element, which has no duration to resolve), and the element itself.
    typealias CopiedElement = (absoluteTick: Int, lengthTicks: Int, element: VoiceElement)

    struct Stream {
        let staff: StaffAddress
        let voiceIndex: Int
        /// The copied material, ascending by tick. A non-timed element carries `lengthTicks == 0` and precedes
        /// a chord at the same tick, which is where it stands in the source voice.
        let elements: [CopiedElement]
        /// Source tuplets whose members are entirely inside this stream, as absolute tick bounds.
        let tuplets: [(startTick: Int, endTick: Int, normalNotes: Int, actualNotes: Int)]
    }

    let streams: [Stream]
    /// Absolute tick the range starts at, on the FIRST staff it covers.
    let startTick: Int
    /// Length of the range in ticks, measured on the first staff.
    let lengthTicks: Int
    let staves: [StaffAddress]

    /// Identifies a stream across the measures it spans. `Voice` (and so `VoiceRef`) is scoped to a single
    /// measure, but a stream is one voice's material across the whole copied range, so streams are keyed on staff
    /// and voice index alone.
    private struct StreamKey: Hashable {
        let staff: StaffAddress
        let voiceIndex: Int
    }

    /// A tuplet's endpoints are `Voice.elements` indices, which only make sense together with the measure that
    /// owns the `Voice` they index into. Ordering one against another is voice order across the whole stream,
    /// which is how the timed and non-timed passes are merged back together.
    fileprivate struct MeasureElementLocation: Hashable, Comparable {
        let measureIndex: Int
        let elementIndex: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.measureIndex, lhs.elementIndex) < (rhs.measureIndex, rhs.elementIndex)
        }
    }

    /// `nil` when the range resolves to no element at all. Throws `.insideTuplet` when the range cuts a tuplet
    /// on either side — a range must cover every tuplet it touches from its first member to its last, through
    /// every nesting level (MuseScore's `Selection::canCopy`, `select.cpp:1394-1465`), so this refuses the whole
    /// copy rather than silently drop the bracket the way an earlier version of this package did.
    init?(range: VoiceElementRange, in score: Score) throws {
        let targets = score.voiceElements(in: range)
        guard !targets.isEmpty,
              let startOnset = score.onset(of: range.start), let endOnset = score.onset(of: range.end),
              let startEnd = score.end(of: range.start), let endEnd = score.end(of: range.end)
        else { return nil }

        // `voiceElements(in:)` yields ids in staff order, so the staff of the first id is the range's first
        // staff regardless of which bound (`start` or `end`) named it.
        var orderedStaves: [StaffAddress] = []
        for target in targets where !orderedStaves.contains(target.staff) {
            orderedStaves.append(target.staff)
        }
        guard let firstStaff = orderedStaves.first else { return nil }
        staves = orderedStaves

        let anchor = RangeCopyGeometry(staff: firstStaff, in: score)
        let low = min(startOnset, endOnset)
        let high = max(startEnd, endEnd)
        guard let start = anchor.absolute(low), let end = anchor.absolute(high) else { return nil }
        startTick = start
        lengthTicks = end - start

        // Which of the caller's two named bounds is the earlier (`lowBound`) and later (`highBound`) one, so a
        // partial-tuplet refusal can name the SPECIFIC bound that lands inside the tuplet rather than either one
        // — `range.start`/`range.end` may be given in either temporal order.
        let lowBound = startOnset <= endOnset ? range.start : range.end
        let highBound = startOnset <= endOnset ? range.end : range.start

        streams = try Self.makeStreams(
            from: targets, in: score, rangeStart: start, rangeEnd: end,
            lowBound: lowBound, highBound: highBound,
        )
        guard !streams.isEmpty else { return nil }
    }
}

extension RangeCopySource {
    static func refused(_ reason: EditRefusal.Reason) -> SheetMusicError {
        .invalidEdit(EditRefusal(operation: "DuplicateRange", reason: reason))
    }

    /// One stream per (staff, voice). `voiceElements(in:)` yields ids in staff, measure, voice, element order, so
    /// appending in encounter order keeps every stream's own elements ascending with no separate sort.
    private static func makeStreams(
        from targets: [VoiceElementID], in score: Score, rangeStart: Int, rangeEnd: Int,
        lowBound: VoiceElementID, highBound: VoiceElementID,
    ) throws -> [Stream] {
        var order: [StreamKey] = []
        var idsByKey: [StreamKey: [VoiceElementID]] = [:]
        for id in targets {
            let key = StreamKey(staff: id.staff, voiceIndex: id.voiceIndex)
            if idsByKey[key] == nil { order.append(key) }
            idsByKey[key, default: []].append(id)
        }

        var geometries: [StaffAddress: RangeCopyGeometry] = [:]
        return try order.compactMap { key in
            let geometry = geometries[key.staff] ?? RangeCopyGeometry(staff: key.staff, in: score)
            geometries[key.staff] = geometry
            guard let ids = idsByKey[key] else { return nil }
            return try makeStream(
                key: key, ids: ids, geometry: geometry, score: score,
                rangeStart: rangeStart, rangeEnd: rangeEnd,
                lowBound: lowBound, highBound: highBound,
            )
        }
    }

    /// Builds one (staff, voice) stream: the copied elements with cleared spanners and outer ties, plus the
    /// tuplets that survived intact. Throws `.insideTuplet` when a tuplet this stream touches is not covered
    /// from its first member to its last (`tupletBounds(for:key:lowBound:highBound:infoByLocation:score:)`).
    ///
    /// The non-timed elements are merged in only after `clearOuterTies` has run, because that pass reaches for
    /// the stream's first and last CHORD — a clef sitting at either end would hide the chord whose outer tie has
    /// to go.
    private static func makeStream(
        key: StreamKey, ids: [VoiceElementID], geometry: RangeCopyGeometry, score: Score,
        rangeStart: Int, rangeEnd: Int,
        lowBound: VoiceElementID, highBound: VoiceElementID,
    ) throws -> Stream? {
        let sourceDurations = score.effectiveMeasureDurations(
            partIndex: key.staff.partIndex, staffIndex: key.staff.staffIndexInPart,
        )
        var elements: [CopiedElement] = []
        var elementLocations: [MeasureElementLocation] = []
        var infoByLocation: [MeasureElementLocation: (tick: Int, length: Int)] = [:]
        for id in ids {
            guard let onset = score.onset(of: id), let absolute = geometry.absolute(onset),
                  var element = score[id], sourceDurations.indices.contains(id.measureIndex),
                  // `tickCount(division:in:)` resolves a `.measure` duration against its own bar's effective
                  // duration; `NoteDuration.ticks(division:)` traps on one, so a whole-bar rest must never reach
                  // it here.
                  let storedLength = element.tickCount(division: score.division, in: sourceDurations[id.measureIndex])
            else { continue }
            // MuseScore's paste opens a gap of exactly the selection's length and shortens the trailing
            // ChordRest to fit it (`read460.cpp:603-633`) rather than copying it whole. `voiceElements(in:)`
            // selects by onset, so an element that starts inside the range but sounds past its end still
            // arrives here — clamp what it reports so the duplicate never runs longer than the range itself.
            let length = min(storedLength, rangeEnd - absolute)
            // Starts at or past the range's end: never really in the range despite the onset test admitting it.
            guard length > 0 else { continue }
            if case var .chord(chord) = element {
                // A slur's stored end is an offset in measures from the chord that starts it, so it cannot
                // survive a copy that may land on a different barring.
                chord.spanners = []
                element = .chord(chord)
            }
            let location = MeasureElementLocation(measureIndex: id.measureIndex, elementIndex: id.elementIndex)
            infoByLocation[location] = (tick: absolute, length: length)
            elementLocations.append(location)
            elements.append((absoluteTick: absolute, lengthTicks: length, element: element))
        }
        guard !elements.isEmpty else { return nil }
        clearOuterTies(&elements)

        let untimed = untimedElements(
            for: ids, key: key, geometry: geometry, durations: sourceDurations, score: score,
            rangeStart: rangeStart, rangeEnd: rangeEnd,
        )
        let tuplets = try tupletBounds(
            for: ids, key: key, lowBound: lowBound, highBound: highBound,
            infoByLocation: infoByLocation, score: score,
        )
        return Stream(
            staff: key.staff, voiceIndex: key.voiceIndex,
            elements: merged(timed: elements, at: elementLocations, untimed: untimed), tuplets: tuplets,
        )
    }

    /// The in-range non-timed elements of one stream, in voice order, each stamped with the tick the voice's
    /// cursor had reached, `lengthTicks == 0`, and the location that puts it back among the chords.
    ///
    /// `Score.voiceElements(in:)` cannot supply these — it filters on `case .chord` — so the voice is walked
    /// directly over the measures the stream's own chords touched. A voice the range does not reach in a given
    /// measure contributes no chord there either, so that measure set is the same one either walk would pick.
    ///
    /// The cursor moves by `cursorAdvance(division:in:)` rather than by summed durations: it is what
    /// `Score.onset(of:)` walks with, so a `.locationShift` among the elements leaves this walk agreeing with
    /// the ticks the chords were stamped with.
    private static func untimedElements(
        for ids: [VoiceElementID], key: StreamKey, geometry: RangeCopyGeometry, durations: [Fraction],
        score: Score, rangeStart: Int, rangeEnd: Int,
    ) -> [(location: MeasureElementLocation, copied: CopiedElement)] {
        var measureOrder: [Int] = []
        for id in ids where !measureOrder.contains(id.measureIndex) {
            measureOrder.append(id.measureIndex)
        }

        var collected: [(location: MeasureElementLocation, copied: CopiedElement)] = []
        for measureIndex in measureOrder {
            let ref = VoiceRef(staff: key.staff, measureIndex: measureIndex, voiceIndex: key.voiceIndex)
            guard let voice = score[voice: ref], durations.indices.contains(measureIndex),
                  geometry.measureStarts.indices.contains(measureIndex)
            else { continue }
            let measureDuration = durations[measureIndex]
            var tick = geometry.measureStarts[measureIndex]
            for index in voice.elements.indices {
                let element = voice.elements[index]
                if isCopyable(element), tick >= rangeStart, tick < rangeEnd {
                    collected.append((
                        location: MeasureElementLocation(measureIndex: measureIndex, elementIndex: index),
                        copied: (absoluteTick: tick, lengthTicks: 0, element: element),
                    ))
                }
                tick += element.cursorAdvance(division: score.division, in: measureDuration)
            }
        }
        return collected
    }

    /// Whether a non-timed element is one MuseScore's paste would accept — clef (`read460.cpp:704-715`), breath
    /// (`717-728`), ambitus, and the segment-annotation list at `664-703`.
    ///
    /// Everything else is false, and for three different reasons. Key signature, time signature and barline are
    /// in the payload but the paste drops them on the floor (`739-744`). `.measureRepeat` stands for a whole
    /// bar's content and `.locationShift` moves the voice's one cursor for the rest of the bar, so neither means
    /// the same thing anywhere else. `.spanner` needs its partner re-anchored, which is its own task.
    /// `.preserved` is markup this library does not model, so there is no knowing whether MuseScore's reader
    /// would take it.
    private static func isCopyable(_ element: VoiceElement) -> Bool {
        switch element {
        case .clef, .breath, .ambitus, .dynamic, .fermata, .harmony, .sticking, .expression, .capo,
             .stringTunings, .figuredBass, .symbol, .fretDiagram:
            true
        case .chord, .keySignature, .timeSignature, .barLine, .measureRepeat, .locationShift, .spanner,
             .preserved:
            false
        }
    }

    /// Merges the two passes back into one stream in SOURCE VOICE ORDER, not by tick.
    ///
    /// The tick cannot decide it: a non-timed element occupies none, so it shares the tick of whatever chord
    /// follows it, and the two would tie. Voice order says which came first, and it is the order that carries the
    /// meaning — an annotation attaches to the segment the chord opens, and a clef placed after its note would be
    /// read as applying to the next one instead. Both lists are already ascending in that order (`ids` arrives
    /// from `voiceElements(in:)` in measure-then-element order, and `untimedElements` walks the same measures in
    /// the same order), so one linear pass is enough. `locations` is parallel to `timed`, one entry per element.
    private static func merged(
        timed: [CopiedElement], at locations: [MeasureElementLocation],
        untimed: [(location: MeasureElementLocation, copied: CopiedElement)],
    ) -> [CopiedElement] {
        guard !untimed.isEmpty, timed.count == locations.count else { return timed }
        var result: [CopiedElement] = []
        result.reserveCapacity(timed.count + untimed.count)
        var timedIndex = timed.startIndex
        var untimedIndex = untimed.startIndex
        while timedIndex < timed.endIndex || untimedIndex < untimed.endIndex {
            let takeUntimed = untimedIndex < untimed.endIndex
                && (timedIndex >= timed.endIndex || untimed[untimedIndex].location < locations[timedIndex])
            if takeUntimed {
                result.append(untimed[untimedIndex].copied)
                untimedIndex += 1
            } else {
                result.append(timed[timedIndex])
                timedIndex += 1
            }
        }
        return result
    }

    /// Tuplets live on the (per-measure) `Voice`, so this walks the distinct measures the stream touched. A
    /// tuplet the copied elements never reach is left alone; one they reach through only SOME of its members is
    /// not something a copy can state — MuseScore refuses the whole operation rather than drop the bracket
    /// (`Selection::canCopy`, `select.cpp:1394-1465`), so this throws `.insideTuplet` naming whichever of the
    /// range's two bounds is the one that landed inside the tuplet, rather than silently keeping only the spans
    /// whose first and last member both survived.
    ///
    /// `ids` is a contiguous, onset-ordered slice of the voice per measure (that is what `voiceElements(in:)`
    /// selects), so within one measure a tuplet's first member is missing only when the covered slice starts
    /// after it (the range's earlier bound, `lowBound`), and its last member is missing only when the slice ends
    /// before it (the range's later bound, `highBound`) — there is no other way for `ids` to touch some of a
    /// tuplet's members without touching its first or last.
    private static func tupletBounds(
        for ids: [VoiceElementID], key: StreamKey, lowBound: VoiceElementID, highBound: VoiceElementID,
        infoByLocation: [MeasureElementLocation: (tick: Int, length: Int)], score: Score,
    ) throws -> [(startTick: Int, endTick: Int, normalNotes: Int, actualNotes: Int)] {
        var measureOrder: [Int] = []
        for id in ids where !measureOrder.contains(id.measureIndex) {
            measureOrder.append(id.measureIndex)
        }

        var tuplets: [(startTick: Int, endTick: Int, normalNotes: Int, actualNotes: Int)] = []
        for measureIndex in measureOrder {
            let ref = VoiceRef(staff: key.staff, measureIndex: measureIndex, voiceIndex: key.voiceIndex)
            guard let voice = score[voice: ref] else { continue }
            let presentIndices = Set(ids.filter { $0.measureIndex == measureIndex }.map(\.elementIndex))
            for span in voice.tupletSpans {
                guard !presentIndices.isDisjoint(with: span.startIndex ... span.endIndex) else { continue }
                let startPresent = presentIndices.contains(span.startIndex)
                let endPresent = presentIndices.contains(span.endIndex)
                guard startPresent, endPresent else {
                    throw Self.refused(.insideTuplet(at: startPresent ? highBound : lowBound))
                }
                let startLocation = MeasureElementLocation(measureIndex: measureIndex, elementIndex: span.startIndex)
                let endLocation = MeasureElementLocation(measureIndex: measureIndex, elementIndex: span.endIndex)
                guard let start = infoByLocation[startLocation], let end = infoByLocation[endLocation]
                else { continue }
                tuplets.append((
                    startTick: start.tick, endTick: end.tick + end.length,
                    normalNotes: span.normalNotes, actualNotes: span.actualNotes,
                ))
            }
        }
        return tuplets
    }
}

/// Clears the stream's outer ties in place: `tieBack` on every note of the first chord, `tieForward` on every
/// note of the last. A tie binds two specific notes and neither partner was copied; a tie between two copied
/// chords stays. `Chord.notes` is a `ChordNotes`, whose only mutation path that keeps a note's identifier is
/// `updateNote(at:_:)`, so notes are edited through their indices rather than rebuilt.
private func clearOuterTies(_ elements: inout [RangeCopySource.CopiedElement]) {
    guard let firstIndex = elements.indices.first, let lastIndex = elements.indices.last else { return }
    if case var .chord(chord) = elements[firstIndex].element {
        for noteIndex in chord.notes.indices {
            chord.notes.updateNote(at: noteIndex) { $0.tieBack = nil }
        }
        elements[firstIndex].element = .chord(chord)
    }
    if case var .chord(chord) = elements[lastIndex].element {
        for noteIndex in chord.notes.indices {
            chord.notes.updateNote(at: noteIndex) { $0.tieForward = nil }
        }
        elements[lastIndex].element = .chord(chord)
    }
}
