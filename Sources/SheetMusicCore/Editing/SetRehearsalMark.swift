import SheetMusicFoundation

/// The system lane's rehearsal-mark reads and writes, shared by both commands and by `ScoreEditSession`'s planners.
///
/// A rehearsal mark is a SYSTEM element (`Score.systemMeasures`), not a voice element, so none of the
/// `MeasureStructure` machinery the note- and signature-level commands lean on applies here: there is no leading
/// run to splice into and no tuplet index to shift. What replaces it is this lane.
enum RehearsalMarkLane {
    /// The rehearsal mark on `measureIndex`, or `nil` when that bar carries none — the first one, on the deliberate
    /// premise that one bar carries one mark (see the plan's decided semantics), which `write` below enforces on
    /// every bar it touches.
    static func mark(in score: Score, measureIndex: Int) -> RehearsalMark? {
        guard score.systemMeasures.indices.contains(measureIndex) else { return nil }
        return mark(in: score.systemMeasures, measureIndex: measureIndex)
    }

    /// The same read against a captured lane, for the inverse's `text`.
    static func mark(in lane: [SystemMeasure], measureIndex: Int) -> RehearsalMark? {
        guard lane.indices.contains(measureIndex) else { return nil }
        for positioned in lane[measureIndex].elements {
            if let mark = mark(of: positioned.element) { return mark }
        }
        return nil
    }

    /// The rehearsal mark `element` carries, or `nil` for any other kind of system element.
    ///
    /// One spelling of the match, so the read, the write and the removal below cannot drift apart into
    /// disagreeing about what counts as a rehearsal mark — the whole lane is three operations over one predicate.
    static func mark(of element: SystemElement) -> RehearsalMark? {
        if case let .rehearsalMark(mark) = element { mark } else { nil }
    }

    /// Grows the lane to one entry per measure, so it stays the PARALLEL lane `InsertMeasure`, `DeleteMeasure` and
    /// `SetTimeSignature`'s splice all test for (`systemMeasures.count == measureCount`) before they will maintain
    /// it. Growing only as far as the bar being written would leave the lane short, and those commands would then
    /// silently stop keeping it aligned with the measures.
    static func pad(_ score: inout Score) {
        let count = MeasureStructure.measureCount(of: score)
        guard score.systemMeasures.count < count else { return }
        score.systemMeasures.append(
            contentsOf: Array(repeating: SystemMeasure(), count: count - score.systemMeasures.count),
        )
    }

    /// Replaces the mark `measure` already carries, or inserts one at the bar's start when it carries none.
    ///
    /// The replace path mutates the existing mark IN PLACE rather than substituting a fresh `RehearsalMark`, for
    /// the reason `SetKeySignature.write` gives about a key: this states which text, not how it is drawn, so an
    /// imported mark's frame, color, offsets and font overrides survive a rename.
    ///
    /// It then COLLAPSES the bar to that one mark, dropping any further rehearsal mark the bar carried. Only an
    /// import can produce a multi-mark bar, but until the collapse the three operations disagreed about what the
    /// bar's mark is: the read above returns the FIRST one, so a rename touched only that, while `removeMarks`
    /// drops them all and the reading surface's mark bar lists every one of them. Enforcing "one bar, one mark" here
    /// turns the premise the read and the removal both already rest on into a fact. Marks past the first are the
    /// only thing dropped — the bar's tempo, system text and swing are not this pair's business.
    ///
    /// The insert lands before the first element positioned later than the bar's start, because
    /// `SystemMeasure.elements` is stored in document order.
    ///
    /// The replace path matches and mutates in ONE pass rather than finding an index and re-binding the mark out
    /// of it. Re-binding needs a second match that the compiler cannot see is the same one, so it needs a failure
    /// branch — and the only honest thing such a branch could do here is silently skip the write, which would turn
    /// a future disagreement between the two matches into a no-op instead of something a test could catch.
    static func write(_ text: String, into measure: inout SystemMeasure) {
        for index in measure.elements.indices {
            guard var existing = mark(of: measure.elements[index].element) else { continue }
            existing.text = text
            measure.elements[index].element = .rehearsalMark(existing)
            var rest = Array(measure.elements[(index + 1)...])
            rest.removeAll { mark(of: $0.element) != nil }
            measure.elements.replaceSubrange((index + 1)..., with: rest)
            return
        }
        let insertion = measure.elements.firstIndex { $0.position > .start } ?? measure.elements.count
        measure.elements.insert(
            PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: text))),
            at: insertion,
        )
    }

    /// Drops every rehearsal mark from `measure`. Every mark rather than the first: the bar's mark is what this
    /// pair addresses, and leaving a second one behind would make the removal look like it had not happened.
    ///
    /// Reports nothing, because its caller decides whether there was anything to remove BEFORE it mutates —
    /// see `RemoveRehearsalMark.apply`.
    static func removeMarks(from measure: inout SystemMeasure) {
        measure.elements.removeAll { mark(of: $0.element) != nil }
    }
}

/// Writes `text` as the rehearsal mark at the head of `measureIndex` — replacing the mark that bar already carries,
/// or creating one where it carried none.
///
/// One bar carries one mark afterwards, whatever it carried before: a bar an import gave several marks is collapsed
/// to the first, renamed. See `RehearsalMarkLane.write`.
///
/// ## The inverse
///
/// A mark write is not reversible by arithmetic: the bar may have carried no mark at all, and the write may have
/// PADDED an empty system lane out to the score's measure count on its way in. So the inverse carries the pre-image
/// — the whole `systemMeasures` lane as it stood — restored verbatim by `init(restoringLane:at:)`, the idiom
/// `SetKeySignature(restoringPrefixes:at:)`, `InsertMeasure(restoredContents:)` and `AddPart(restoring:at:)` use.
///
/// The lane rather than the one bar, even though only one bar changes: `Score.systemMeasures` is one small struct
/// per measure — usually with an empty element array — and a whole-lane capture restores the padding as part of the
/// same value, where a per-bar capture would have to re-derive whether it had padded at all.
public struct SetRehearsalMark: EditCommand {
    public let measureIndex: Int
    /// The text to write, trimmed by `apply`. On the restore path this is the text the captured lane puts back —
    /// `apply` ignores it there and splices the pre-image instead.
    public let text: String
    /// Set only when this command is the inverse of a `SetRehearsalMark` / `RemoveRehearsalMark`: the score's whole
    /// system lane as it stood before that edit.
    let restoredLane: [SystemMeasure]?

    public init(measureIndex: Int, text: String) {
        self.measureIndex = measureIndex
        self.text = text
        restoredLane = nil
    }

    init(restoringLane lane: [SystemMeasure], at measureIndex: Int) {
        self.measureIndex = measureIndex
        restoredLane = lane
        text = RehearsalMarkLane.mark(in: lane, measureIndex: measureIndex)?.text ?? ""
    }

    /// A rehearsal mark belongs to the system rather than to a staff, so there is no voice element to name. Part 0 /
    /// staff 0 / voice 0 / element 0 of the bar is what the other bar-addressing commands report
    /// (`SetKeySignature`, `RemoveTimeSignature`), and the session only reads `measureIndex` off it.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        // One place states the range, for the same reason `SetKeySignature` does: the answer is the same whether
        // the command is reached through an intent or built directly.
        guard measureIndex >= 0, measureIndex < MeasureStructure.measureCount(of: score), !score.parts.isEmpty
        else { throw Self.refused(.targetNotFound(affectedLocation)) }

        let previous = score.systemMeasures
        if let restoredLane {
            score.systemMeasures = restoredLane
        } else {
            // `SheetMusicFoundation`'s equivalent, for the reason `setRehearsalMarkCommand` gives: `CharacterSet`
            // is absent from `FoundationEssentials`, so the Foundation spelling does not build for wasm.
            let trimmed = text.trimmingWhitespaceAndNewlines()
            guard !trimmed.isEmpty else { throw Self.refused(.emptyRehearsalMarkText) }
            RehearsalMarkLane.pad(&score)
            RehearsalMarkLane.write(trimmed, into: &score.systemMeasures[measureIndex])
        }
        return SetRehearsalMark(restoringLane: previous, at: measureIndex)
    }
}

/// Removes the rehearsal mark at `measureIndex`.
///
/// Refused with `.targetNotFound` when the bar carries none. That case is the PLANNER's to resolve to nothing
/// (`ScoreEditSession+RehearsalMarkPlanning` returns `nil`, which the session reports as `.nothingToApply`); the
/// throw here is what the same command answers when it is built directly, so the range and the emptiness are both
/// stated in one place — exactly the split `RemoveKeySignature` uses.
///
/// Unlike the signature removals there is no measure-0 exception: bar 1's rehearsal mark is a mark like any other,
/// not the score declaring something the engraver needs.
public struct RemoveRehearsalMark: EditCommand {
    public let measureIndex: Int

    public init(measureIndex: Int) {
        self.measureIndex = measureIndex
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard measureIndex >= 0, measureIndex < MeasureStructure.measureCount(of: score), !score.parts.isEmpty,
              score.systemMeasures.indices.contains(measureIndex)
        else { throw Self.refused(.targetNotFound(affectedLocation)) }

        // Decided against the untouched score, before anything is written: a refused removal then cannot have
        // changed the score, as a property of the order rather than of `removeMarks` happening to report
        // truthfully afterwards.
        guard RehearsalMarkLane.mark(in: score, measureIndex: measureIndex) != nil
        else { throw Self.refused(.targetNotFound(affectedLocation)) }

        let previous = score.systemMeasures
        RehearsalMarkLane.removeMarks(from: &score.systemMeasures[measureIndex])
        return SetRehearsalMark(restoringLane: previous, at: measureIndex)
    }
}
