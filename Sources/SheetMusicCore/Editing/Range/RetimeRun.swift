import SheetMusicFoundation

/// Gives each chord and rest of a run a new length IN PLACE and keeps everything else about it — the edit a
/// mistyped rhythm needs, a dotted eighth and a sixteenth that should have been two eighths.
///
/// The run is the `durations.count` consecutive chords and rests of `location`'s measure and voice, starting at
/// `location`; each takes the duration at its position, and a rest stays a rest. Elements that are not chords or
/// rests — a dynamic, a chord symbol, a breath, a spanner marker — between them keep their place in element order,
/// so each stays at the onset of the chord after it wherever that onset moves. The element count never changes, so
/// no index anywhere moves.
///
/// Neither obvious composition does this. `SetDurationInRange`, like the `SetChordDuration` under it, shortens by
/// writing a filler rest and lengthens by swallowing what follows, so a pair re-timed through it gains a rest or
/// loses a note; `PasteRange` of a rebuilt run clears every spanner reaching into the span it writes. Here the new
/// total must equal the old one, so nothing is filled in and nothing is swallowed.
///
/// What is measured against the onsets that move is restated against the score this command leaves, so it stays on
/// the same elements:
///
/// - every spanner of the run's staff and voice — a `.spanner` element, or a slur in `Chord.spanners` — whose begin
///   or end the re-time moves gets its `nextMeasuresOffset` / `nextFractionsOffset` rewritten from its begin's new
///   onset to the new onset of the element it ended on;
/// - every lyric melisma (`Lyric.ticks`) of that voice that starts in the run, or ends inside or after it, is
///   rewritten to end on the same chord;
/// - every staff text of the run's staff on a member's old onset moves to the member's new onset — unless another
///   voice of the staff has a chord or rest starting at that tick, when the text may be that element's and stays.
///   Tempo, swing and system text belong to the whole system and stay where they are.
///
/// An end that fell part-way through a member rather than on an onset keeps its proportion of that member. Other
/// voices' spanners and melismas are not restated: each is measured against its own voice, which does not move.
///
/// Refused, with nothing planned:
///
/// - `.targetNotFound(location)` when `location` does not resolve, or fewer than `durations.count` chords and rests
///   remain in the bar from it — a run never crosses a barline;
/// - `.wrongElementKind` when `location` is neither a chord nor a rest, and for `.measure` asked of a chord with
///   notes, a bar-filling length being a rest's spelling only;
/// - `.insideTuplet` naming the first member inside a tuplet, whose length is the tuplet's to decide;
/// - `.insufficientRoom(neededTicks: newTotal, availableTicks: oldTotal)` when the totals differ, or when a length
///   is not positive — that would make room out of nothing.
///
/// Durations every member already has plan to nothing.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` (× element), plus one system-lane bar written back
/// > wholesale when a staff text moves, bundled in a `CompositeEditCommand`. See `docs/edit-commands.md`.
public struct RetimeRun: EditCommand {
    public let location: VoiceElementID
    public let durations: [NoteDuration]

    public init(at location: VoiceElementID, durations: [NoteDuration]) {
        self.location = location
        self.durations = durations
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let composite = try plan(in: score) else {
            return CompositeEditCommand(commands: [], location: location)
        }
        return try composite.apply(to: &score, ids: &ids)
    }

    /// The composite this command would apply to `score`, or `nil` when it would change nothing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned one
    /// refuse identically.
    ///
    /// Takes no allocator, unlike its range siblings: every write keeps the identity of the element it rewrites,
    /// so nothing is minted.
    func plan(in score: Score) throws -> CompositeEditCommand? {
        let members = try run(in: score)
        guard let staff = score[location.staff] else { throw Self.refused(.targetNotFound(location)) }
        let measureDurations = staff.measures.effectiveMeasureDurations()
        let lengths = try tickLengths(
            of: members, division: score.division, measureDuration: measureDurations[location.measureIndex],
        )
        guard zip(members, durations).contains(where: { member, duration in member.chord.duration != duration })
        else { return nil }

        var retimed = score
        for (member, duration) in zip(members, durations) {
            var chord = member.chord
            chord.duration = duration
            retimed[member.id] = .chord(chord)
        }
        var retiming = RunRetiming(measureDurations: measureDurations, division: score.division)
        let spans = zip(members, lengths).compactMap { member, length -> RunRetiming.Span? in
            guard let oldStart = retiming.tick(of: member.id, in: score),
                  let newStart = retiming.tick(of: member.id, in: retimed)
            else { return nil }
            return RunRetiming.Span(
                oldStart: oldStart, oldLength: length.old, newStart: newStart, newLength: length.new,
            )
        }
        retiming.spans = spans

        var rewritten = members.map(\.id)
        rewritten += restateSpanners(from: score, into: &retimed, retiming: retiming)
        rewritten += restateMelismas(from: score, into: &retimed, retiming: retiming)
        var seen = Set<VoiceElementID>()
        var commands: [any EditCommand] = rewritten.compactMap { id in
            guard seen.insert(id).inserted, let element = retimed[id], element != score[id] else { return nil }
            return ReplaceVoiceElement(at: id, with: element)
        }
        if let lane = movedStaffTexts(in: score, retiming: retiming) {
            commands.append(ReplaceSystemMeasure(location: location, measure: lane))
        }
        return commands.isEmpty ? nil : CompositeEditCommand(commands: commands, location: location)
    }
}

// MARK: - The run

extension RetimeRun {
    /// One chord or rest of the run, as it stands before the re-time.
    private struct Member {
        let id: VoiceElementID
        let chord: Chord
    }

    /// The run's members in element order. Throws `.targetNotFound`, `.wrongElementKind` and `.insideTuplet`.
    private func run(in score: Score) throws -> [Member] {
        guard let voice = score[voice: VoiceRef(location)],
              voice.elements.indices.contains(location.elementIndex)
        else { throw Self.refused(.targetNotFound(location)) }
        guard case .chord = voice.elements[location.elementIndex] else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chordOrRest))
        }
        var members: [Member] = []
        var index = location.elementIndex
        while members.count < durations.count, index < voice.elements.count {
            if case let .chord(chord) = voice.elements[index] {
                members.append(Member(id: location.withElementIndex(index), chord: chord))
            }
            index += 1
        }
        guard members.count == durations.count else { throw Self.refused(.targetNotFound(location)) }
        for member in members {
            try DurationChangeAlgorithm.ensureNotInsideTuplet(
                voice: voice, at: member.id, operation: String(describing: Self.self),
            )
        }
        return members
    }

    /// Each member's length before and after, in ticks. Throws `.wrongElementKind` for `.measure` on a chord with
    /// notes, and `.insufficientRoom` unless every new length is positive and the two totals agree.
    private func tickLengths(
        of members: [Member], division: Int, measureDuration: Fraction,
    ) throws -> [(old: Int, new: Int)] {
        var lengths: [(old: Int, new: Int)] = []
        for (member, duration) in zip(members, durations) {
            if case .measure = duration, !member.chord.notes.isEmpty {
                throw Self.refused(.wrongElementKind(at: member.id, expected: .rest))
            }
            lengths.append((
                old: member.chord.duration.resolved(in: measureDuration).ticks(division: division),
                new: duration.resolved(in: measureDuration).ticks(division: division),
            ))
        }
        let oldTotal = lengths.reduce(0) { $0 + $1.old }
        let newTotal = lengths.reduce(0) { $0 + $1.new }
        guard newTotal == oldTotal, lengths.allSatisfy({ $0.new > 0 }) else {
            throw Self.refused(.insufficientRoom(neededTicks: newTotal, availableTicks: oldTotal))
        }
        return lengths
    }
}

// MARK: - What is measured against the run

extension RetimeRun {
    /// Element `element` of bar `measure`, in the run's staff and voice.
    private func slot(_ element: Int, measure: Int) -> VoiceElementID {
        VoiceElementID(
            staff: location.staff, measureIndex: measure, voiceIndex: location.voiceIndex, elementIndex: element,
        )
    }

    /// Restates, in `retimed`, every spanner of the run's staff and voice whose begin or end the re-time moved,
    /// and answers the elements it rewrote.
    ///
    /// Found and written through the re-bar's own walk (`SetTimeSignature+SpannerWalk.swift`), which already knows
    /// both storage shapes and which of a chord's slurs an address names. Only bars up to the run's can reach into
    /// it: an end never precedes its begin.
    ///
    /// A spanner declaring no endpoint — offset 0 and a fraction worth no ticks, which is also every end marker —
    /// is left alone, as the re-bar leaves it, and so is one ending past the last bar, which every consumer clamps.
    private func restateSpanners(
        from score: Score, into retimed: inout Score, retiming: RunRetiming,
    ) -> [VoiceElementID] {
        let found = TimeSignatureRegion.spanners(inRegion: 0 ..< location.measureIndex + 1, of: score).filter {
            $0.partIndex == location.staff.partIndex && $0.staffIndex == location.staff.staffIndexInPart
                && $0.voiceIndex == location.voiceIndex
        }
        var rewritten: [VoiceElementID] = []
        for spanner in found {
            let id = slot(spanner.elementIndex, measure: spanner.measureIndex)
            let declared = spanner.fraction?.ticks(division: score.division) ?? 0
            let endBar = spanner.measureIndex + spanner.offset
            guard spanner.offset != 0 || declared != 0, retiming.barStarts.indices.contains(endBar),
                  let oldStart = retiming.tick(of: id, in: score), let newStart = retiming.tick(of: id, in: retimed)
            else { continue }
            // MuseScore's `<next>` is relative to the begin side's own tick: whole bars from its bar, then the
            // fraction from its place in that bar (`HairpinRamps.computeEndTick`, `LayoutEngine.endAnchor`).
            let beginRtick = oldStart - retiming.barStarts[spanner.measureIndex]
            let oldEnd = retiming.barStarts[endBar] + beginRtick + declared
            let newEnd = retiming.mapped(oldEnd)
            guard newStart != oldStart || newEnd != oldEnd,
                  let offsets = Spanner.offsets(from: id, to: retiming.position(of: newEnd), in: retimed),
                  var element = retimed[id]
            else { continue }
            TimeSignatureRegion.setOffsets(
                (offsets.measures, offsets.fractions), at: spanner.spannerIndex, in: &element,
            )
            retimed[id] = element
            rewritten.append(id)
        }
        return rewritten
    }

    /// Restates, in `retimed`, every melisma of the run's voice whose start or end the re-time moved, and answers
    /// the chords it rewrote. `Lyric.ticks` targets the chord beginning that many ticks after the syllable's own,
    /// so the end is carried across as a tick and the length re-read from the syllable's new onset.
    private func restateMelismas(
        from score: Score, into retimed: inout Score, retiming: RunRetiming,
    ) -> [VoiceElementID] {
        guard let staff = score[location.staff] else { return [] }
        var rewritten: [VoiceElementID] = []
        for measureIndex in 0 ... location.measureIndex {
            let voices = staff.measures[measureIndex].voices
            guard voices.indices.contains(location.voiceIndex) else { continue }
            let elements = voices[location.voiceIndex].elements
            for elementIndex in elements.indices {
                guard case let .chord(chord) = elements[elementIndex], chord.lyrics.contains(where: { $0.ticks > 0 })
                else { continue }
                let id = slot(elementIndex, measure: measureIndex)
                guard let oldStart = retiming.tick(of: id, in: score),
                      let newStart = retiming.tick(of: id, in: retimed),
                      case let .chord(current)? = retimed[id]
                else { continue }
                var updated = current
                for index in updated.lyrics.indices where updated.lyrics[index].ticks > 0 {
                    let ticks = retiming.mapped(oldStart + updated.lyrics[index].ticks) - newStart
                    if ticks > 0 { updated.lyrics[index].ticks = ticks }
                }
                guard updated != current else { continue }
                retimed[id] = .chord(updated)
                rewritten.append(id)
            }
        }
        return rewritten
    }

    /// The run's bar of the system lane with each staff text of the run's staff that sat on a moving member's old
    /// onset moved to the member's new one, or `nil` when none moves.
    ///
    /// A staff text is addressed by its beat (`SetStaffText`), not by an element, so the beat stands for the member
    /// only when nothing else on the staff starts there: where another voice has a chord or rest at that tick, the
    /// text may be that element's, and it stays. A text is the run's staff's by `SetStaffText`'s rule — its
    /// `originalStaff`, or the canonical staff for one that names none. Tempo, swing and system text are the whole
    /// system's and never move. A moved text is put back in document order, before the first element positioned
    /// after it, keeping its identity.
    private func movedStaffTexts(in score: Score, retiming: RunRetiming) -> SystemMeasure? {
        let bar = MeasureRef(measureIndex: location.measureIndex)
        guard let lane = score[system: bar], let measure = score[measure: bar, staff: location.staff]
        else { return nil }
        let barStart = retiming.barStarts[location.measureIndex]
        let measureDuration = retiming.measureDurations[location.measureIndex]
        // The bar ticks where another voice of the staff starts a chord or rest.
        var taken = Set<Int>()
        for (voiceIndex, voice) in measure.voices.enumerated() where voiceIndex != location.voiceIndex {
            var tick = 0
            for element in voice.elements {
                if case .chord = element { taken.insert(tick) }
                tick += element.cursorAdvance(division: score.division, in: measureDuration)
            }
        }
        let lanePosition = { (staffTick: Int) in
            MeasurePosition(numerator: staffTick - barStart, denominator: 4 * score.division)
        }
        var moves: [MeasurePosition: MeasurePosition] = [:]
        for span in retiming.spans where span.newStart != span.oldStart && !taken.contains(span.oldStart - barStart) {
            moves[lanePosition(span.oldStart)] = lanePosition(span.newStart)
        }
        guard !moves.isEmpty else { return nil }
        var kept: [(EID, PositionedSystemElement)] = []
        var moved: [(EID, PositionedSystemElement)] = []
        for index in lane.elements.indices {
            var positioned = lane.elements[index]
            if case let .staffText(text) = positioned.element, !text.isSystemText,
               (positioned.originalStaff ?? Score.canonicalStaff) == location.staff,
               let target = moves[positioned.position]
            {
                positioned.position = target
                moved.append((lane.elements.eid(at: index), positioned))
            } else {
                kept.append((lane.elements.eid(at: index), positioned))
            }
        }
        guard !moved.isEmpty else { return nil }
        for entry in moved {
            kept.insert(entry, at: kept.firstIndex { $0.1.position > entry.1.position } ?? kept.count)
        }
        var updated = lane
        updated.elements = IdentifiedArray(kept)
        return updated
    }
}

/// Writes one bar of the system lane wholesale and answers the command that writes it back — how `RetimeRun` moves
/// a staff text inside the composite that re-times the chord under it. `SetStaffText`'s pre-image idiom, one bar
/// wide.
private struct ReplaceSystemMeasure: EditCommand {
    let location: VoiceElementID
    let measure: SystemMeasure

    var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    func apply(to score: inout Score, ids _: inout EIDAllocator) throws -> any EditCommand {
        let bar = MeasureRef(measureIndex: location.measureIndex)
        guard let previous = score[system: bar] else { throw Self.refused(.targetNotFound(location)) }
        score[system: bar] = measure
        return ReplaceSystemMeasure(location: location, measure: previous)
    }
}

/// The run's staff measured in ticks from its start, and where the re-time carries a tick on it.
private struct RunRetiming {
    /// One member's span before and after the re-time, in staff ticks.
    struct Span {
        let oldStart: Int
        let oldLength: Int
        let newStart: Int
        let newLength: Int
    }

    let measureDurations: [Fraction]
    /// Where each bar starts. A re-time inside one bar changes no bar's length, so one table serves both scores.
    let barStarts: [Int]
    var spans: [Span] = []

    init(measureDurations: [Fraction], division: Int) {
        self.measureDurations = measureDurations
        var starts: [Int] = []
        var total = 0
        for duration in measureDurations {
            starts.append(total)
            total += duration.ticks(division: division)
        }
        barStarts = starts
    }

    /// The onset of `id` in `score`, in staff ticks.
    func tick(of id: VoiceElementID, in score: Score) -> Int? {
        guard barStarts.indices.contains(id.measureIndex),
              let onset = score.onset(of: id, measureDuration: measureDurations[id.measureIndex])
        else { return nil }
        return barStarts[id.measureIndex] + onset.tick
    }

    /// Where `tick` lands after the re-time: at the same proportion of the member whose old span holds it, and
    /// unmoved outside every member. A member's onset maps to its new onset, which is what keeps an end that sat ON
    /// an element on that element.
    func mapped(_ tick: Int) -> Int {
        for span in spans where span.oldLength > 0 && span.oldStart <= tick && tick < span.oldStart + span.oldLength {
            return span.newStart + (tick - span.oldStart) * span.newLength / span.oldLength
        }
        return tick
    }

    /// `tick` as a bar and a tick inside it — the last bar starting at or before it, the form
    /// `Spanner.offsets(from:to:in:)` rolls a bar-line tick forward from.
    func position(of tick: Int) -> ScoreTickPosition {
        let bar = barStarts.lastIndex { $0 <= tick } ?? 0
        return ScoreTickPosition(measure: bar, tick: tick - (barStarts.indices.contains(bar) ? barStarts[bar] : 0))
    }
}
