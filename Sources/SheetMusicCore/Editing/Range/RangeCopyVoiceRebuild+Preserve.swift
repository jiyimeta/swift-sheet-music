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
    static func leadingTrim(of entry: Entry, upTo spanStart: Int, in context: Context) -> [VoiceSlot] {
        guard case let .chord(chord) = entry.element else { return [] }
        let durations = DurationChangeAlgorithm.alignedDurations(
            forTicks: spanStart - entry.start, rtickStart: entry.start, division: context.division,
        )
        guard let first = durations.first else { return [] }
        var head = chord
        head.duration = first
        for index in head.notes.indices {
            head.notes.updateNote(at: index) { $0.tieForward = 1 }
        }
        var slots = [VoiceSlot(identity: .keep(entry.eid), element: .chord(head))]
        let continuation = Array(durations.dropFirst())
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
    /// the boundary element's identity.
    static func trailingTrim(of entry: Entry, from spanEnd: Int, in context: Context) -> [VoiceSlot] {
        guard case let .chord(chord) = entry.element else { return [] }
        let durations = DurationChangeAlgorithm.alignedDurations(
            forTicks: entry.end - spanEnd, rtickStart: spanEnd, division: context.division,
        )
        guard !durations.isEmpty else { return [] }
        let pieces: [VoiceElement] = chord.notes.isEmpty
            ? durations.map { .rest(duration: $0) }
            : DurationChangeAlgorithm.makeChordChain(
                from: chord, durations: durations, onsetOwnership: .allContinuation,
            )
        return pieces.map { VoiceSlot(identity: .fresh, element: $0) }
    }

    /// `makeChordChain` only knows about its own slice: it clears `tieBack` on its first piece and restores the
    /// source's own `tieForward` on its last. The leading trim's continuation is the middle of a chain whose
    /// head is the kept boundary element, so both ends are tied.
    private static func tiedChain(from chord: Chord, durations: [NoteDuration]) -> [VoiceElement] {
        var pieces = DurationChangeAlgorithm.makeChordChain(
            from: chord, durations: durations, onsetOwnership: .allContinuation,
        )
        if let first = pieces.indices.first { pieces[first] = settingTie(pieces[first], back: 1) }
        if let last = pieces.indices.last { pieces[last] = settingTie(pieces[last], forward: 1) }
        return pieces
    }

    /// Sets `tieBack` and/or `tieForward` on every note of a chord element; a `nil` argument leaves that side
    /// as it is. `Chord.notes` is a `ChordNotes`, whose only mutation path that keeps a note's identifier is
    /// `updateNote(at:_:)`, so notes are edited through their indices rather than rebuilt.
    private static func settingTie(_ element: VoiceElement, back: Int? = nil, forward: Int? = nil) -> VoiceElement {
        guard case var .chord(chord) = element else { return element }
        for index in chord.notes.indices {
            chord.notes.updateNote(at: index) {
                if let back { $0.tieBack = back }
                if let forward { $0.tieForward = forward }
            }
        }
        return .chord(chord)
    }
}
