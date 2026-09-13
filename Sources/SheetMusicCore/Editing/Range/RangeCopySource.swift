import SheetMusicFoundation

/// The material a `DuplicateRange` copies: the range's chords and rests, grouped by the voice they live in and
/// stamped with the absolute tick each one starts at.
///
/// Resolution goes through `Score.voiceElements(in:)` so the source is exactly what every other range command acts
/// on — one resolution rule for the whole family, and a range that names two staves or is given end-first behaves
/// here as it does there. Non-timed elements are not collected: `voiceElements(in:)` already restricts itself to
/// `.chord` elements (which is also how rests are represented in this model), so a duplicate carries notes and
/// rests, per the spec.
struct RangeCopySource {
    struct Stream {
        let staff: StaffAddress
        let voiceIndex: Int
        /// Chords and rests only, each with the absolute tick it starts at and its length already resolved
        /// against the SOURCE bar, ascending.
        let elements: [(absoluteTick: Int, lengthTicks: Int, element: VoiceElement)]
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
    /// owns the `Voice` they index into.
    private struct MeasureElementLocation: Hashable {
        let measureIndex: Int
        let elementIndex: Int
    }

    /// `nil` when the range resolves to no element at all.
    init?(range: VoiceElementRange, in score: Score) {
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

        streams = Self.makeStreams(from: targets, in: score, rangeEnd: end)
        guard !streams.isEmpty else { return nil }
    }
}

extension RangeCopySource {
    /// One stream per (staff, voice). `voiceElements(in:)` yields ids in staff, measure, voice, element order, so
    /// appending in encounter order keeps every stream's own elements ascending with no separate sort.
    private static func makeStreams(from targets: [VoiceElementID], in score: Score, rangeEnd: Int) -> [Stream] {
        var order: [StreamKey] = []
        var idsByKey: [StreamKey: [VoiceElementID]] = [:]
        for id in targets {
            let key = StreamKey(staff: id.staff, voiceIndex: id.voiceIndex)
            if idsByKey[key] == nil { order.append(key) }
            idsByKey[key, default: []].append(id)
        }

        var geometries: [StaffAddress: RangeCopyGeometry] = [:]
        return order.compactMap { key in
            let geometry = geometries[key.staff] ?? RangeCopyGeometry(staff: key.staff, in: score)
            geometries[key.staff] = geometry
            guard let ids = idsByKey[key] else { return nil }
            return makeStream(key: key, ids: ids, geometry: geometry, score: score, rangeEnd: rangeEnd)
        }
    }

    /// Builds one (staff, voice) stream: the copied elements with cleared spanners and outer ties, plus the
    /// tuplets that survived intact.
    private static func makeStream(
        key: StreamKey, ids: [VoiceElementID], geometry: RangeCopyGeometry, score: Score, rangeEnd: Int,
    ) -> Stream? {
        let sourceDurations = score.effectiveMeasureDurations(
            partIndex: key.staff.partIndex, staffIndex: key.staff.staffIndexInPart,
        )
        var elements: [(absoluteTick: Int, lengthTicks: Int, element: VoiceElement)] = []
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
            elements.append((absoluteTick: absolute, lengthTicks: length, element: element))
        }
        guard !elements.isEmpty else { return nil }
        clearOuterTies(&elements)

        let tuplets = tupletBounds(for: ids, key: key, infoByLocation: infoByLocation, score: score)
        return Stream(staff: key.staff, voiceIndex: key.voiceIndex, elements: elements, tuplets: tuplets)
    }

    /// Tuplets live on the (per-measure) `Voice`, so this walks the distinct measures the stream touched and keeps
    /// only spans whose FIRST and LAST member both survived the copy — a partially covered tuplet has no ratio
    /// left to state.
    private static func tupletBounds(
        for ids: [VoiceElementID], key: StreamKey,
        infoByLocation: [MeasureElementLocation: (tick: Int, length: Int)], score: Score,
    ) -> [(startTick: Int, endTick: Int, normalNotes: Int, actualNotes: Int)] {
        var measureOrder: [Int] = []
        for id in ids where !measureOrder.contains(id.measureIndex) {
            measureOrder.append(id.measureIndex)
        }

        var tuplets: [(startTick: Int, endTick: Int, normalNotes: Int, actualNotes: Int)] = []
        for measureIndex in measureOrder {
            let ref = VoiceRef(staff: key.staff, measureIndex: measureIndex, voiceIndex: key.voiceIndex)
            guard let voice = score[voice: ref] else { continue }
            for span in voice.tupletSpans {
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
private func clearOuterTies(_ elements: inout [(absoluteTick: Int, lengthTicks: Int, element: VoiceElement)]) {
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
