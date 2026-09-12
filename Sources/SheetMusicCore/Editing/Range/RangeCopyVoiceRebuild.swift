import SheetMusicFoundation

/// Writes one `RangeCopyPlacement.Piece` into a destination voice, respecting everything already there: the
/// material in front of the replaced tick span, the material behind it, the halves of the boundary elements the
/// span only partly covers, the non-timed elements standing inside it, and the voice's own tuplets.
///
/// The result is one `ReplaceVoiceElements` built from SLOTS rather than from finished elements, because only
/// the landing apply may mint identifiers — planning runs against a copy of the allocator, and an identifier
/// minted here would not be covered by the live one. Copied and rebuilt material is therefore `.fresh` (whose
/// nested note identifiers `VoiceSlot.materialize` clears and reassigns) and surviving material is
/// `.keep(its existing EID)`.
enum RangeCopyVoiceRebuild {
    /// The `ReplaceVoiceElements` that writes `piece` into `(staff, piece.measureIndex, voiceIndex)`.
    static func command(
        for piece: RangeCopyPlacement.Piece, staff: StaffAddress, voiceIndex: Int, in score: Score,
    ) throws -> ReplaceVoiceElements {
        let ref = VoiceRef(staff: staff, measureIndex: piece.measureIndex, voiceIndex: voiceIndex)
        let measureDurations = score.effectiveMeasureDurations(
            partIndex: staff.partIndex, staffIndex: staff.staffIndexInPart,
        )
        guard let voice = score[voice: ref], measureDurations.indices.contains(piece.measureIndex) else {
            throw refused(.targetNotFound(VoiceElementID(
                staff: staff, measureIndex: piece.measureIndex, voiceIndex: voiceIndex, elementIndex: 0,
            )))
        }
        guard !piece.elements.isEmpty else { throw refused(.emptyPayload) }

        let context = Context(
            division: score.division, measureDuration: measureDurations[piece.measureIndex], ref: ref,
        )
        let spanStart = piece.startTickInMeasure
        let spanEnd = spanStart + piece.elements.reduce(0) { $0 + context.advance(of: $1) }
        // Nothing downstream notices a span that runs off the end of the bar: `cut` files the elements past it
        // into neither `after` nor `trailing`, the rebuild therefore drops them, and `ReplaceVoiceElements`
        // validates no lengths — so an over-long voice would be written silently. The caller should never send
        // one, and this is the guard that makes that true of this unit on its own rather than by trust.
        let measureTicks = context.measureDuration.ticks(division: context.division)
        guard spanEnd <= measureTicks else {
            throw refused(.insufficientRoom(neededTicks: spanEnd, availableTicks: measureTicks))
        }
        let cut = try cut(voice, spanStart: spanStart, spanEnd: spanEnd, in: context)
        let survivors = try survivingTuplets(of: voice, touched: cut.touched)
        let rebuilt = rebuild(piece, cut: cut, spanStart: spanStart, spanEnd: spanEnd, in: context)

        return ReplaceVoiceElements(
            staff: staff, measureIndex: piece.measureIndex, voiceIndex: voiceIndex, slots: rebuilt.slots,
            tupletSlots: tupletSlots(survivors: survivors, of: voice, piece: piece, rebuilt: rebuilt),
        )
    }

    static func refused(_ reason: EditRefusal.Reason) -> SheetMusicError {
        .invalidEdit(EditRefusal(operation: "DuplicateRange", reason: reason))
    }
}

extension RangeCopyVoiceRebuild {
    /// What a rebuild needs throughout and none of it changes while one runs.
    struct Context {
        let division: Int
        let measureDuration: Fraction
        let ref: VoiceRef

        /// How far `element` moves the voice's running tick. Never sum `NoteDuration.ticks(division:)` instead:
        /// only `cursorAdvance` resolves a `.measure` rest (the plain call traps on one) and honors a
        /// `.locationShift`, and it is what `Score.onset(of:)` and `Score.voiceElements(in:)` walk with, so
        /// anything else disagrees with how the range was resolved in the first place.
        func advance(of element: VoiceElement) -> Int {
            element.cursorAdvance(division: division, in: measureDuration)
        }

        func location(_ elementIndex: Int) -> VoiceElementID {
            VoiceElementID(
                staff: ref.staff, measureIndex: ref.measureIndex, voiceIndex: ref.voiceIndex,
                elementIndex: elementIndex,
            )
        }
    }

    /// One destination element as the walk saw it.
    struct Entry {
        let index: Int
        let eid: EID
        let element: VoiceElement
        let start: Int
        let advance: Int

        /// A chord — which is also how this model spells a rest. Everything else occupies no tick budget of its
        /// own, even a `.locationShift`, which moves the cursor without being material that can be trimmed.
        var isTimed: Bool {
            if case .chord = element { true } else { false }
        }

        var end: Int {
            start + advance
        }
    }

    /// How the replaced tick span falls across the destination voice.
    struct Cut {
        var before: [Entry] = []
        var after: [Entry] = []
        /// Non-timed elements standing inside the span — a mid-bar clef, a signature, a dynamic. Re-emitted at
        /// their own tick rather than dropped.
        var preserved: [Entry] = []
        /// The element the span starts inside, when it does not start on an element boundary.
        var leading: Entry?
        /// The element the span ends inside, when it does not end on an element boundary.
        var trailing: Entry?
        /// The destination element indices the span touches; `nil` when it touches nothing.
        var touched: ClosedRange<Int>?
    }

    /// The rebuilt slot list and the two index maps a tuplet needs to name its members in it.
    struct Rebuilt {
        var slots: [VoiceSlot] = []
        /// Where each of the piece's own elements landed in `slots`.
        var pieceSlotIndices: [Int] = []
        /// Where each surviving destination element landed in `slots`, so a kept tuplet can be ordered by its
        /// first member's new position.
        var keptIndexByEID: [EID: Int] = [:]
    }
}

extension RangeCopyVoiceRebuild {
    /// The whole new slot array, in voice order: what precedes the span, the leading boundary element's
    /// remainder, the piece with the preserved non-timed elements spliced back in, the trailing boundary
    /// element's remainder, and what follows the span.
    private static func rebuild(
        _ piece: RangeCopyPlacement.Piece, cut: Cut, spanStart: Int, spanEnd: Int, in context: Context,
    ) -> Rebuilt {
        var rebuilt = Rebuilt()
        for entry in cut.before {
            rebuilt.keep(entry)
        }
        if let leading = cut.leading {
            rebuilt.slots += leadingTrim(of: leading, upTo: spanStart, in: context)
        }

        var pending = cut.preserved
        var cursor = spanStart
        for element in piece.elements {
            while let next = pending.first, next.start <= cursor {
                rebuilt.keep(next)
                pending.removeFirst()
            }
            rebuilt.pieceSlotIndices.append(rebuilt.slots.count)
            rebuilt.slots.append(VoiceSlot(identity: .fresh, element: element))
            cursor += context.advance(of: element)
        }
        for entry in pending {
            rebuilt.keep(entry)
        }

        if let trailing = cut.trailing {
            rebuilt.slots += trailingTrim(of: trailing, from: spanEnd, in: context)
        }
        for entry in cut.after {
            rebuilt.keep(entry)
        }
        return rebuilt
    }

    /// Surviving destination tuplets keep their `.element` endpoints under `.keep`; a carried one has to name
    /// its members by `.index`, since a `.fresh` slot has no identifier until `VoiceSlot.materialize` gives it
    /// one on the same apply that `TupletSlot.materialize` resolves the indices on.
    ///
    /// Emitted in span order. `Voice.==` compares `tupletSpans` as an ordered array and `stableFingerprint`
    /// hashes them in stored order, so a voice whose spans are out of order compares unequal to its own round
    /// trip.
    private static func tupletSlots(
        survivors: [Int], of voice: Voice, piece: RangeCopyPlacement.Piece, rebuilt: Rebuilt,
    ) -> [TupletSlot] {
        let spans = voice.tupletSpans
        var ordered: [(order: Int, slot: TupletSlot)] = survivors.map { index in
            let eid = voice.tuplets.eid(at: index)
            let firstEID = voice.elements.eid(at: spans[index].startIndex)
            return (
                order: rebuilt.keptIndexByEID[firstEID] ?? spans[index].startIndex,
                slot: TupletSlot(identity: .keep(eid), tuplet: voice.tuplets[index]),
            )
        }
        for carried in piece.tuplets {
            let indices = rebuilt.pieceSlotIndices
            guard indices.indices.contains(carried.range.lowerBound),
                  indices.indices.contains(carried.range.upperBound)
            else { continue }
            let start = indices[carried.range.lowerBound]
            ordered.append((order: start, slot: TupletSlot(identity: .fresh, tuplet: Tuplet(
                normalNotes: carried.normalNotes, actualNotes: carried.actualNotes,
                startIndex: start, endIndex: indices[carried.range.upperBound],
            ))))
        }
        // `sorted(by:)` is not stable, so the original position breaks ties rather than the comparison leaving
        // two spans starting on the same slot in an arbitrary order.
        return ordered.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element.slot)
    }
}

extension RangeCopyVoiceRebuild.Rebuilt {
    /// Appends a surviving destination element under its existing identifier, recording where it landed.
    mutating func keep(_ entry: RangeCopyVoiceRebuild.Entry) {
        keptIndexByEID[entry.eid] = slots.count
        slots.append(VoiceSlot(identity: .keep(entry.eid), element: entry.element))
    }
}
