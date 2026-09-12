import SheetMusicFoundation

/// What the destination keeps: the walk that says which of its elements the span touches, the rules that refuse
/// what cannot be written over, and the two boundary trims.
extension RangeCopyVoiceRebuild {
    /// Walks the destination voice once, sorting every element into what precedes the span, what follows it,
    /// what it half-covers, and what stands inside it without occupying tick budget.
    static func cut(_ voice: Voice, spanStart: Int, spanEnd: Int, in context: Context) throws -> Cut {
        var result = Cut()
        var tick = 0
        var low: Int?
        var high: Int?
        for index in voice.elements.indices {
            let element = voice.elements[index]
            let entry = Entry(
                index: index, eid: voice.elements.eid(at: index), element: element,
                start: tick, advance: context.advance(of: element),
            )
            tick = entry.end
            guard entry.isTimed else {
                try place(untimed: entry, spanStart: spanStart, spanEnd: spanEnd, into: &result, in: context)
                if entry.start >= spanStart, entry.start < spanEnd {
                    low = min(low ?? index, index)
                    high = max(high ?? index, index)
                }
                continue
            }
            if entry.end <= spanStart {
                result.before.append(entry)
            } else if entry.start >= spanEnd {
                result.after.append(entry)
            } else {
                if entry.start < spanStart { result.leading = entry }
                if entry.end > spanEnd { result.trailing = entry }
                low = min(low ?? index, index)
                high = max(high ?? index, index)
            }
        }
        if let low, let high { result.touched = low ... high }
        return result
    }

    /// A non-timed element is placed by its own tick alone: it has no extent to be half-covered by.
    ///
    /// One inside the span is re-emitted where it stood — except a `.locationShift` or a `.measureRepeat`,
    /// which are refused. A jog moves the voice's one cursor for the rest of the bar, and a measure repeat
    /// stands for the whole bar's content; neither can be carried through material written over the ticks it
    /// governs without changing what the bar means.
    private static func place(
        untimed entry: Entry, spanStart: Int, spanEnd: Int, into result: inout Cut, in context: Context,
    ) throws {
        guard entry.start >= spanStart, entry.start < spanEnd else {
            if entry.start < spanStart { result.before.append(entry) } else { result.after.append(entry) }
            return
        }
        switch entry.element {
        case .locationShift, .measureRepeat:
            throw refused(.blockedByUntimedElement(at: context.location(entry.index)))
        default:
            result.preserved.append(entry)
        }
    }

    /// The destination tuplets that survive, as indices into `voice.tuplets`.
    ///
    /// A tuplet the span fully contains is dropped — the rule `PasteVoiceElements` already applies, since the
    /// bracket's members are being replaced wholesale — and one the span only partly covers is refused: the
    /// members left behind no longer state the ratio the bracket printed.
    static func survivingTuplets(of voice: Voice, touched: ClosedRange<Int>?) throws -> [Int] {
        var survivors: [Int] = []
        for (index, span) in voice.tupletSpans.enumerated() {
            // A dangling endpoint resolves to -1. Such a tuplet draws nothing, so it is not carried forward.
            guard span.startIndex >= 0, span.endIndex >= 0 else { continue }
            guard let touched else {
                survivors.append(index)
                continue
            }
            guard touched.lowerBound <= span.endIndex, span.startIndex <= touched.upperBound else {
                survivors.append(index)
                continue
            }
            guard touched.lowerBound <= span.startIndex, span.endIndex <= touched.upperBound else {
                throw refused(.tupletOverlap(
                    rangeStart: touched.lowerBound, rangeEnd: touched.upperBound,
                    tupletStart: span.startIndex, tupletEnd: span.endIndex,
                ))
            }
        }
        return survivors
    }

    /// The part of `entry` that stays in front of the span, `[entry.start, spanStart)`.
    ///
    /// The head keeps the boundary element's identity: it is the same onset, only shorter, so the performer's
    /// element is still there. Its continuation pieces are new material and mint fresh identifiers.
    ///
    /// No tie leaves the trim's far end. What follows it is copied material from somewhere else in the score —
    /// usually a different pitch — not the rest of this note, so a tie across that seam asserts a bond between
    /// two notes that are not partners. A tie the SOURCE already carried there is cleared too: it pointed at
    /// whatever stood after the original element, and the copy has overwritten exactly that. Ties INSIDE the
    /// trim stay, because those pieces really are one note.
    static func leadingTrim(of entry: Entry, upTo spanStart: Int, in context: Context) -> [VoiceSlot] {
        guard case let .chord(chord) = entry.element else { return [] }
        let durations = DurationChangeAlgorithm.alignedDurations(
            forTicks: spanStart - entry.start, rtickStart: entry.start, division: context.division,
        )
        guard let first = durations.first else { return [] }
        var head = chord
        head.duration = first
        let continuation = Array(durations.dropFirst())
        // The head is the trim's far end only when nothing follows it inside the trim.
        let headElement = settingTie(.chord(head), forward: continuation.isEmpty ? .clear : .set(1))
        var slots = [VoiceSlot(identity: .keep(entry.eid), element: headElement)]
        guard !continuation.isEmpty else { return slots }
        let pieces: [VoiceElement] = chord.notes.isEmpty
            ? continuation.map { .rest(duration: $0) }
            : tiedChain(from: chord, durations: continuation)
        slots += pieces.map { VoiceSlot(identity: .fresh, element: $0) }
        return slots
    }

    /// The part of `entry` that stays behind the span, `[spanEnd, entry.end)`.
    ///
    /// All of it is new material: the onset it belonged to was consumed by the copy, so nothing here may keep
    /// the boundary element's identity. Its first piece carries no `tieBack` for the mirror of the reason the
    /// leading trim carries no `tieForward` — the copy in front of it is not this note's beginning.
    static func trailingTrim(of entry: Entry, from spanEnd: Int, in context: Context) -> [VoiceSlot] {
        guard case let .chord(chord) = entry.element else { return [] }
        let durations = DurationChangeAlgorithm.alignedDurations(
            forTicks: entry.end - spanEnd, rtickStart: spanEnd, division: context.division,
        )
        guard !durations.isEmpty else { return [] }
        var pieces: [VoiceElement] = chord.notes.isEmpty
            ? durations.map { .rest(duration: $0) }
            : DurationChangeAlgorithm.makeChordChain(
                from: chord, durations: durations, onsetOwnership: .allContinuation,
            )
        // `.allContinuation` already leaves the first piece untied backwards; stated here so the invariant
        // survives a change of ownership mode rather than depending on one.
        if let first = pieces.indices.first { pieces[first] = settingTie(pieces[first], back: .clear) }
        return pieces.map { VoiceSlot(identity: .fresh, element: $0) }
    }

    /// `makeChordChain` only knows about its own slice: it clears `tieBack` on its first piece and restores the
    /// source's own `tieForward` on its last. The leading trim's continuation hangs off the kept head, so it
    /// ties back to it — and it ends the trim, so its far end is cleared.
    private static func tiedChain(from chord: Chord, durations: [NoteDuration]) -> [VoiceElement] {
        var pieces = DurationChangeAlgorithm.makeChordChain(
            from: chord, durations: durations, onsetOwnership: .allContinuation,
        )
        if let first = pieces.indices.first { pieces[first] = settingTie(pieces[first], back: .set(1)) }
        if let last = pieces.indices.last { pieces[last] = settingTie(pieces[last], forward: .clear) }
        return pieces
    }

    /// What to do with one side of a note's tie. `.leave` is not the same as `.clear`: a trim keeps the tie
    /// that binds it to material the span never touched, and drops only the one that would cross the seam.
    private enum TieChange {
        case leave
        case set(Int)
        case clear

        func applied(to value: Int?) -> Int? {
            switch self {
            case .leave: value
            case let .set(new): new
            case .clear: nil
            }
        }
    }

    /// Rewrites `tieBack` and/or `tieForward` on every note of a chord element. `Chord.notes` is a
    /// `ChordNotes`, whose only mutation path that keeps a note's identifier is `updateNote(at:_:)`, so notes
    /// are edited through their indices rather than rebuilt.
    private static func settingTie(
        _ element: VoiceElement, back: TieChange = .leave, forward: TieChange = .leave,
    ) -> VoiceElement {
        guard case var .chord(chord) = element else { return element }
        for index in chord.notes.indices {
            chord.notes.updateNote(at: index) {
                $0.tieBack = back.applied(to: $0.tieBack)
                $0.tieForward = forward.applied(to: $0.tieForward)
            }
        }
        return .chord(chord)
    }
}
