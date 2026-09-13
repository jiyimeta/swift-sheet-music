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
        sealBoundaryTies(in: &result)
        return result
    }

    /// Clears the tie a boundary neighbour no longer has a partner for.
    ///
    /// When the span's edge falls exactly on an element boundary, the main walk above produces no leading or
    /// trailing trim: the neighbouring destination chord is filed into `before`/`after` untouched, ties and all.
    /// Left alone it would still point across the seam at whatever the copy puts there — usually a different
    /// pitch. `leadingTrim`/`trailingTrim` already do this for the half-covered case; this is the same rule for
    /// the case where there is no trim to carry it. MuseScore's own removal clears both tie ends of the note it
    /// takes out (`editing/addremoveelement.cpp:203-224`); this applies that to the one side that survives.
    ///
    /// `before.last` is the boundary chord whenever `leading` is `nil` and `before` is non-empty: ticks are
    /// contiguous, so nothing can be filed into `before` after the element whose end lands exactly on
    /// `spanStart`. The search on the `after` side is not similarly free: an untimed element sharing the
    /// boundary chord's tick (a mid-bar clef, say) can be appended first, so the boundary chord is found by kind
    /// rather than by position.
    private static func sealBoundaryTies(in cut: inout Cut) {
        if cut.leading == nil, let index = cut.before.lastIndex(where: \.isTimed) {
            cut.before[index] = retied(cut.before[index], forward: .clear)
        }
        if cut.trailing == nil, let index = cut.after.firstIndex(where: \.isTimed) {
            cut.after[index] = retied(cut.after[index], back: .clear)
        }
    }

    /// `Entry` is immutable, so rewriting a note's tie means rebuilding the entry around the changed element.
    private static func retied(_ entry: Entry, back: TieChange = .leave, forward: TieChange = .leave) -> Entry {
        Entry(
            index: entry.index, eid: entry.eid,
            element: settingTie(entry.element, back: back, forward: forward),
            start: entry.start, advance: entry.advance,
        )
    }

    /// A non-timed element is placed by its own tick alone: it has no extent to be half-covered by.
    ///
    /// One inside the span is refused, kept, or dropped by kind. A `.locationShift` or a `.measureRepeat` is
    /// refused: a jog moves the voice's one cursor for the rest of the bar, and a measure repeat stands for the
    /// whole bar's content, so neither can be carried through material written over the ticks it governs
    /// without changing what the bar means.
    ///
    /// A clef, a signature, a barline, a breath, or unmodeled `.preserved` markup is re-emitted at
    /// its own tick, matching MuseScore, where these live on their own segment types rather than as the
    /// annotations `makeGap1`'s `deleteAnnotationsFromRange` clears (`cmd.cpp:1504`, `edit.cpp:3734-3759`). An
    /// ambitus is kept for a different reason: MuseScore holds it in the segment's element list rather than
    /// among its annotations, so no gap pass reaches it at all. A dynamic, fermata, harmony, and the rest of
    /// the segment-annotation family are cleared instead — the copy landing on them is exactly what that
    /// MuseScore pass destroys. A `.spanner` is decided by `spannerFate(of:anchoredAt:spanStart:spanEnd:in:)`.
    /// Every kind kept here is kept UNCONDITIONALLY; `rebuild(_:cut:gap:spanStart:spanEnd:in:)` drops a clef,
    /// breath or harmony afterward when the piece brings one of the same kind to the same tick, via
    /// `pieceSupersededSlots(in:from:in:)`.
    ///
    /// > Important: `SupersededKind` must stay EXACTLY the intersection of `RangeCopySource.isCopyable(_:)` and
    /// > the kinds this function preserves. Three exhaustive switches encode that invariant with no compiler
    /// > link between them: exhaustiveness catches a NEW `VoiceElement` case, and nothing at all catches an
    /// > existing case moved from one bucket to another. Moving a kind into or out of either list means
    /// > revisiting all three — a kind the copy carries but this drops would leave the destination's copy of it
    /// > superseded by nothing, and a kind this preserves that the copy does not carry can never be superseded
    /// > and so must not be named here.
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
        case let .spanner(spanner):
            guard spannerSurvivesGap(
                spanner, anchoredAt: entry.start, spanStart: spanStart, spanEnd: spanEnd, in: context,
            ) else { break }
            result.preserved.append(entry)
        case .clef, .keySignature, .timeSignature, .barLine, .breath, .ambitus, .preserved, .harmony:
            result.preserved.append(entry)
        case .dynamic, .fermata, .sticking, .expression, .capo, .stringTunings, .figuredBass, .symbol,
             .fretDiagram:
            break
        case .chord:
            preconditionFailure("place(untimed:...) is only reached for a non-timed entry")
        }
    }

    /// Whether a `.spanner` ANCHORED inside the gap is re-emitted rather than removed with the material it was
    /// anchored to — `makeGap1`'s `deleteOrShortenOutSpannersFromRange` (`edit.cpp:3638-3702`), read in its own
    /// order.
    ///
    /// The pass first skips a volta and anything system-flagged (`:3659`), which is why a volta survives here
    /// whatever its extent. Then comes the branch that is KIND-AGNOSTIC: a spanner whose start lies in
    /// `[t1, t2)` and whose end lies in `(t1, t2]` is removed outright (`:3683-3685`), pedal and text line
    /// included. Only after that does the four-kind set (`:3641-3646`) gate anything, and it gates the
    /// `moveStart` / `moveEnd` shorten branches alone (`:3690-3698`). So a hairpin, ottava, trill or vibrato
    /// anchored here is removed either way — wholly inside it goes with the gap, and reaching past it, it is
    /// re-written at the gap's far edge by `RangeCopySpanners.restart(_:in:ids:commands:)` — while any other
    /// kind anchored here that reaches PAST the gap is outside the pass entirely and stays put.
    ///
    /// The remaining outcome this walk cannot see is a spanner reaching INTO the gap from an earlier bar; that
    /// one is `RangeCopySpanners.clearDestination`'s, which works from the score's own absolute axis.
    private static func spannerSurvivesGap(
        _ spanner: Spanner, anchoredAt anchorTick: Int, spanStart: Int, spanEnd: Int, in context: Context,
    ) -> Bool {
        guard spanner.kind != .volta else { return true }
        if RangeCopySpanners.isShortenedOutOfGaps(spanner.kind) { return false }
        guard let measureStart = context.measureStart,
              let absoluteEnd = RangeCopySpanners.endTick(
                  of: spanner, anchoredAt: ScoreTickPosition(measure: context.ref.measureIndex, tick: anchorTick),
                  geometry: context.geometry, division: context.division,
              )
        else { return true }
        let end = absoluteEnd - measureStart
        return !(end > spanStart && end <= spanEnd)
    }

    /// A non-timed kind a segment holds only ONE of per track, so a copied element of that kind takes the
    /// destination's place rather than standing beside it.
    ///
    /// MuseScore's paste replaces rather than adds: clef and breath go through `undoChangeElement`
    /// (`read460.cpp:704-715`, `717-728`), and a chord symbol is dropped from the destination on the same
    /// condition (`656-661`, with `cmd.cpp:1502`). Without this, duplicating onto a bar that already carries a
    /// mid-bar clef would leave the destination's clef AND the copied one at a single tick — which is not
    /// something a score can mean, and not what MuseScore writes.
    ///
    /// `nil` for every other element: a kind the copy does not carry has nothing to lose its place to, and a
    /// kind that can legitimately repeat at one tick must not be deduplicated by tick either.
    ///
    /// > Important: this list is EXACTLY the intersection of `RangeCopySource.isCopyable(_:)` and the kinds
    /// > `place(untimed:spanStart:spanEnd:into:in:)` preserves, and nothing in the compiler ties the three
    /// > switches together. Read that function's note before moving a kind between buckets.
    enum SupersededKind: Hashable {
        case clef
        case breath
        case harmony

        init?(_ element: VoiceElement) {
            switch element {
            case .clef: self = .clef
            case .breath: self = .breath
            case .harmony: self = .harmony
            case .locationShift, .measureRepeat, .spanner, .keySignature, .timeSignature, .barLine, .preserved,
                 .ambitus, .dynamic, .fermata, .sticking, .expression, .capo, .stringTunings, .figuredBass,
                 .symbol, .fretDiagram, .chord:
                return nil
            }
        }
    }

    /// One (kind, tick) pair the piece about to be written occupies.
    struct SupersededSlot: Hashable {
        let kind: SupersededKind
        let tick: Int
    }

    /// Every (kind, tick) at which `elements` — the piece about to be written, walked from `origin` — brings a
    /// non-timed element that supersedes the destination's.
    ///
    /// A carried non-timed element advances the cursor by nothing, so it shares the tick of the chord it
    /// precedes — which is exactly the tick a destination element has to stand at to be the one it replaces.
    static func pieceSupersededSlots(
        in elements: [VoiceElement], from origin: Int, in context: Context,
    ) -> Set<SupersededSlot> {
        var slots: Set<SupersededSlot> = []
        var cursor = origin
        for element in elements {
            if let kind = SupersededKind(element) { slots.insert(SupersededSlot(kind: kind, tick: cursor)) }
            cursor += context.advance(of: element)
        }
        return slots
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
    enum TieChange {
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
    static func settingTie(
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
