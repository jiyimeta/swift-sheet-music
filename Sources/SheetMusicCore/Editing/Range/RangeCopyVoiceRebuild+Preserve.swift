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
    /// One inside the span is refused, kept, or dropped by kind. A `.locationShift` or a `.measureRepeat` is
    /// refused: a jog moves the voice's one cursor for the rest of the bar, and a measure repeat stands for the
    /// whole bar's content, so neither can be carried through material written over the ticks it governs
    /// without changing what the bar means.
    ///
    /// A clef, a signature, a barline, a breath, an ambitus, or unmodeled `.preserved` markup is re-emitted at
    /// its own tick, matching MuseScore, where these live on their own segment types rather than as the
    /// annotations `makeGap1`'s `deleteAnnotationsFromRange` clears (`cmd.cpp:1504`, `edit.cpp:3734-3759`). A
    /// dynamic, fermata, harmony, and the rest of the segment-annotation family are cleared instead — the copy
    /// landing on them is exactly what that MuseScore pass destroys. A `.spanner` goes the same way unless it is
    /// a volta, which is skipped. A `.harmony` is kept here unconditionally; `rebuild(_:cut:gap:
    /// spanStart:spanEnd:in:)` drops it afterward when the piece brings one of its own to the same tick, via
    /// `pieceHarmonyTicks(in:from:in:)`.
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
        case let .spanner(spanner) where spanner.kind == .volta:
            result.preserved.append(entry)
        case .spanner:
            // A line spanner ANCHORED in the gap is removed with the material it was anchored to —
            // `makeGap1`'s `deleteOrShortenOutSpannersFromRange` (`edit.cpp:3638-3702`). One anchored before
            // the gap is shortened instead, which this walk never sees; `RangeCopySpanners.clearDestination`
            // does it from the score's own axis. A volta is skipped (`:3659`) and so is caught above.
            break
        case .clef, .keySignature, .timeSignature, .barLine, .breath, .ambitus, .preserved, .harmony:
            result.preserved.append(entry)
        case .dynamic, .fermata, .sticking, .expression, .capo, .stringTunings, .figuredBass, .symbol,
             .fretDiagram:
            break
        case .chord:
            preconditionFailure("place(untimed:...) is only reached for a non-timed entry")
        }
    }

    /// The ticks at which `elements` — the piece about to be written, walked from `origin` — places a harmony
    /// of its own.
    ///
    /// A carried chord symbol advances the cursor by nothing, so it shares the tick of the chord it precedes —
    /// which is exactly the tick a destination symbol would have to stand at to be the one MuseScore replaces.
    static func pieceHarmonyTicks(in elements: [VoiceElement], from origin: Int, in context: Context) -> Set<Int> {
        var ticks: Set<Int> = []
        var cursor = origin
        for element in elements {
            if case .harmony = element { ticks.insert(cursor) }
            cursor += context.advance(of: element)
        }
        return ticks
    }

    /// The tick span the rebuild actually clears: the piece's own span, widened over every destination tuplet
    /// it covers only partly.
    ///
    /// MuseScore does not refuse a gap that cuts a tuplet at the DESTINATION. By the time `makeGap` is making
    /// room the operation is already committed, so it deletes the whole top-level tuplet and respells the part
    /// of it the gap does not cover as plain rests (`cmd.cpp:1370-1392`, `1403-1432`). The asymmetry with the
    /// source side — where `RangeCopySource` still refuses a range that cuts a tuplet — is deliberate: nothing
    /// has happened yet when the range is read, so refusing there costs nothing.
    ///
    /// Widening is a fixpoint rather than a single pass, and NOT because one tuplet can reach into the next:
    /// sibling tuplets never overlap, so swallowing one can only reach material that lies between them. The
    /// two shapes that do need a second pass are a NESTED tuplet — nothing in this package mints one, but
    /// `MSCXDecoder+Voice.swift` builds them off a `tupletStack`, so a loaded file can carry one, and widening
    /// over the outer bracket is what brings the inner one's extent inside the gap — and a malformed voice
    /// whose spans genuinely overlap, which must still terminate on a covering gap rather than loop.
    static func clearedGap(
        forSpan spanStart: Int, _ spanEnd: Int, of voice: Voice, in context: Context,
    ) -> Range<Int> {
        var starts: [Int] = []
        var ends: [Int] = []
        var tick = 0
        for element in voice.elements.values {
            starts.append(tick)
            tick += context.advance(of: element)
            ends.append(tick)
        }
        var low = spanStart
        var high = spanEnd
        // `tupletSpans` is computed: it re-resolves every bracket's two endpoints against `elements` on each
        // read, so the loop below must not be the thing that reads it.
        let spans = voice.tupletSpans
        var widened = true
        while widened {
            widened = false
            for span in spans {
                // A dangling endpoint resolves to -1, and such a tuplet draws nothing.
                guard starts.indices.contains(span.startIndex), ends.indices.contains(span.endIndex) else {
                    continue
                }
                let start = starts[span.startIndex]
                let end = ends[span.endIndex]
                // Only a tuplet the gap reaches INTO but does not already cover moves either bound.
                guard start < high, low < end, start < low || end > high else { continue }
                low = min(low, start)
                high = max(high, end)
                widened = true
            }
        }
        return low ..< high
    }

    /// The destination tuplets that survive, as indices into `voice.tuplets`.
    ///
    /// A tuplet the cleared gap reaches is dropped — the rule `PasteVoiceElements` already applies, since the
    /// bracket's members are being replaced wholesale. `clearedGap(forSpan:_:of:in:)` ran first, so every
    /// tuplet `touched` reaches is covered from its first member to its last by the time this runs, and the
    /// ticks of a destroyed one that the piece does not fill come back as plain rests.
    static func survivingTuplets(of voice: Voice, touched: ClosedRange<Int>?) -> [Int] {
        var survivors: [Int] = []
        for (index, span) in voice.tupletSpans.enumerated() {
            // A dangling endpoint resolves to -1. Such a tuplet draws nothing, so it is not carried forward.
            guard span.startIndex >= 0, span.endIndex >= 0 else { continue }
            let reached = touched.map { $0.lowerBound <= span.endIndex && span.startIndex <= $0.upperBound }
            if reached != true { survivors.append(index) }
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
