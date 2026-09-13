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
        /// Spanners lying entirely inside the range, as absolute SOURCE tick bounds. They travel beside
        /// `elements` rather than inside them — see `RangeCopySpanners` for why nothing rides through the
        /// placement — and are re-anchored at the destination by `RangeCopySpanners.recreate(_:at:…)`.
        let spanners: [RangeCopySpanners.Copied]
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
    struct MeasureElementLocation: Hashable, Comparable {
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
    ///
    /// `operation` names the command this resolution is serving — `DuplicateRange` reads a range of the score
    /// being edited, `PasteRange` reads a payload's own whole extent through `init?(payload:)` — and it stamps
    /// whichever refusal `.insideTuplet` above raises. There is deliberately no default: this initializer is
    /// shared by both, and a default would quietly restore the bug where a paste refused in here was reported
    /// to the host as a repeat-selection.
    /// The extent comes from `Extent.init?(range:in:)`, the one place that derivation lives, and is handed to
    /// `init?(extent:in:operation:)`, which is where the resolution itself lives. A range is the special case of
    /// an extent whose four facts happen to be readable off a pair of slots.
    init?(range: VoiceElementRange, in score: Score, operation: String) throws {
        guard let extent = Extent(range: range, in: score) else { return nil }
        try self.init(extent: extent, in: score, operation: operation)
    }

    /// The three payload facts a relocated copy has to restate. `RangeCopySource+Payload.swift` is the only
    /// caller: `PasteRange` re-addresses a payload's streams onto the destination's staves, and every other
    /// field of the resolved source — the material, the ticks, the tuplets, the spanners — carries over
    /// untouched.
    init(streams: [Stream], startTick: Int, lengthTicks: Int, staves: [StaffAddress]) {
        self.streams = streams
        self.startTick = startTick
        self.lengthTicks = lengthTicks
        self.staves = staves
    }
}

extension RangeCopySource {
    /// A refusal stamped with the CALLING command's name. There is deliberately no default, for the reason
    /// `init?(range:in:operation:)` gives: this resolution is shared by `DuplicateRange` and `PasteRange`.
    static func refused(_ reason: EditRefusal.Reason, operation: String) -> SheetMusicError {
        .invalidEdit(EditRefusal(operation: operation, reason: reason))
    }

    /// One stream per (staff, voice). `voiceElements(staves:from:to:)` yields ids in staff, measure, voice,
    /// element order, so appending in encounter order keeps every stream's own elements ascending with no
    /// separate sort. Internal rather than private because `init?(extent:in:operation:)`, the one caller, lives
    /// in `RangeCopySource+Extent.swift`.
    static func makeStreams(
        from targets: [VoiceElementID], in score: Score, rangeStart: Int, rangeEnd: Int,
        lowBound: VoiceElementID, highBound: VoiceElementID, operation: String,
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
                lowBound: lowBound, highBound: highBound, operation: operation,
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
        lowBound: VoiceElementID, highBound: VoiceElementID, operation: String,
    ) throws -> Stream? {
        let sourceDurations = score.effectiveMeasureDurations(
            partIndex: key.staff.partIndex, staffIndex: key.staff.staffIndexInPart,
        )
        var elements: [CopiedElement] = []
        var elementLocations: [MeasureElementLocation] = []
        var infoByLocation: [MeasureElementLocation: (tick: Int, length: Int)] = [:]
        var spanners: [RangeCopySpanners.Copied] = []
        let tupletMembers = tupletMemberLocations(
            for: ids, staff: key.staff, voiceIndex: key.voiceIndex, score: score,
        )
        for id in ids {
            guard let onset = score.onset(of: id), let absolute = geometry.absolute(onset),
                  var element = score[id], sourceDurations.indices.contains(id.measureIndex),
                  // `tickCount(division:in:)` resolves a `.measure` duration against its own bar's effective
                  // duration; `NoteDuration.ticks(division:)` traps on one, so a whole-bar rest must never reach
                  // it here.
                  let storedLength = element.tickCount(division: score.division, in: sourceDurations[id.measureIndex])
            else { continue }
            let location = MeasureElementLocation(measureIndex: id.measureIndex, elementIndex: id.elementIndex)
            // MuseScore's paste opens a gap of exactly the selection's length and shortens the trailing
            // ChordRest to fit it (`read460.cpp:603-633`) rather than copying it whole. `voiceElements(in:)`
            // selects by onset, so an element that starts inside the range but sounds past its end still
            // arrives here — clamp what it reports so the duplicate never runs longer than the range itself.
            //
            // A TUPLET MEMBER is exempt, exactly as MuseScore exempts it: `if (!cr->tuplet())` guards the
            // shorten (`read460.cpp:626-629`, "we don't allow copy of partial tuplet anyhow"). This is
            // reachable even though `tupletBounds(for:…)` refuses a partially covered tuplet, because that
            // refusal is about ONSETS: every member can be selected while the last member's END still falls
            // past the range. Clamping there would truncate that member and re-spell it, leaving the carried
            // bracket naming a member count the voice no longer has.
            let length = tupletMembers.contains(location)
                ? storedLength
                : min(storedLength, rangeEnd - absolute)
            // Starts at or past the range's end: never really in the range despite the onset test admitting it.
            guard length > 0 else { continue }
            if case var .chord(chord) = element {
                // A slur's stored end is an offset in measures from the chord that starts it, so it cannot
                // survive a copy that may land on a different barring: the ones lying wholly inside the range
                // are set aside here and re-anchored at the destination, and the chord travels with an empty
                // array either way.
                spanners += RangeCopySpanners.take(
                    from: &chord, at: onset, absoluteTick: absolute, geometry: geometry,
                    division: score.division, range: rangeStart ..< rangeEnd,
                )
                element = .chord(chord)
            }
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
            for: ids, staff: key.staff, voiceIndex: key.voiceIndex, lowBound: lowBound, highBound: highBound,
            infoByLocation: infoByLocation, score: score, operation: operation,
        )
        spanners += RangeCopySpanners.lineSpanners(
            for: ids, staff: key.staff, voiceIndex: key.voiceIndex, geometry: geometry,
            durations: sourceDurations, score: score, range: rangeStart ..< rangeEnd,
        )
        return Stream(
            staff: key.staff, voiceIndex: key.voiceIndex,
            elements: merged(timed: elements, at: elementLocations, untimed: untimed), tuplets: tuplets,
            spanners: spanners,
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
    /// (`717-728`) and the segment-annotation list at `664-703`.
    ///
    /// Everything else is false, and for four different reasons. Key signature, time signature and barline are
    /// in the payload but the paste drops them on the floor (`739-744`). An ambitus is in the payload too and
    /// has no branch of its own at all: it falls into the same catch-all, which logs "element %s not handled"
    /// and skips it. `.measureRepeat` stands for a whole bar's content and `.locationShift` moves the voice's
    /// one cursor for the rest of the bar, so neither means the same thing anywhere else. `.spanner` needs its
    /// partner re-anchored against the destination's own barring, so it travels beside the elements rather than
    /// among them — `RangeCopySpanners.lineSpanners(for:…)` collects it and `RangeCopySpanners.recreate(_:at:…)`
    /// writes it back. `.preserved` is markup this library does not model, so there is no knowing whether
    /// MuseScore's reader would take it.
    ///
    /// > Important: the kinds this answers true for, intersected with the kinds
    /// > `RangeCopyVoiceRebuild.place(untimed:spanStart:spanEnd:into:in:)` preserves, must be exactly
    /// > `RangeCopyVoiceRebuild.SupersededKind`. Read that function's note before moving a kind in or out.
    private static func isCopyable(_ element: VoiceElement) -> Bool {
        switch element {
        case .clef, .breath, .dynamic, .fermata, .harmony, .sticking, .expression, .capo,
             .stringTunings, .figuredBass, .symbol, .fretDiagram:
            true
        case .chord, .keySignature, .timeSignature, .barLine, .measureRepeat, .locationShift, .spanner,
             .ambitus, .preserved:
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
