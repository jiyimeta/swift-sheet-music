import SheetMusicFoundation

/// A length change on a chord or rest INSIDE a tuplet — MuseScore's `Score::changeCRlen` with its `tuplet` argument
/// (`engraving/editing/cmd.cpp`).
///
/// **The requested length is a WRITTEN value, and the tuplet's ratio is applied to it.** MuseScore compares and fills
/// in `TDuration`s — what the reader sees on the note — and steps the tick cursor by `actualTicks(…, tuplet, …)`.
/// So with a quarter's worth of triplet eighths selected on the first, a quarter makes that note a triplet QUARTER
/// (two thirds of the beat) that takes the second note's time, and the beat now divides 2:1; a sixteenth makes it a
/// triplet sixteenth and fills the rest of its old time with a triplet-sixteenth rest. Members carry their scaled
/// length the way the MSCX decoder writes them (`written × normalNotes / actualNotes`, as a `.fraction`), so the
/// encoder and the renderers read the result like any decoded tuplet.
///
/// **The tuplet's time never changes.** Shortening fills the gap with rests inside the bracket; lengthening consumes
/// the members that follow and stops at the bracket's end — asking for more than the tuplet has left is refused, as
/// it is in MuseScore, rather than tearing the tuplet down. A member consumed only in part leaves its remainder as
/// rests, or, for a chord, as a tied chain of clones — the same rule `DurationChangeAlgorithm.compute` applies
/// outside a tuplet. The bracket's `last` endpoint follows the new last member.
///
/// Out of scope (refused): a tuplet nested in another or holding one, a length whose scaled ticks are not whole,
/// and an untimed element inside the bracket.
enum TupletDurationChange {
    /// `nil` when the element at `idx` is in no tuplet — the caller then takes its ordinary path.
    static func compute( // swiftlint:disable:this function_body_length
        in voice: Voice, atIdx idx: Int, mutatedTarget: VoiceElement, written: NoteDuration, division: Int,
        baseLocation: VoiceElementID, operation: String, ids: inout EIDAllocator,
    ) throws -> (elements: IdentifiedArray<VoiceElement>, tuplets: IdentifiedArray<Tuplet>)? {
        let spans = voice.tupletSpans
        let containing = spans.indices.filter { spans[$0].startIndex <= idx && idx <= spans[$0].endIndex }
        guard let spanIndex = containing.first else { return nil }
        let span = spans[spanIndex]
        let holdsAnother = spans.indices.contains {
            $0 != spanIndex && spans[$0].startIndex >= span.startIndex && spans[$0].endIndex <= span.endIndex
        }
        func refuse(_ reason: EditRefusal.Reason) -> SheetMusicError {
            .invalidEdit(EditRefusal(operation: operation, reason: reason))
        }
        guard containing.count == 1, !holdsAnother, span.normalNotes > 0, span.actualNotes > 0,
              case let .chord(target) = voice.elements[idx], case let .chord(mutated) = mutatedTarget
        else { throw refuse(.insideTuplet(at: baseLocation)) }

        let scale = Scale(normal: span.normalNotes, actual: span.actualNotes, division: division)
        guard let actualDuration = scale.actual(written) else { throw refuse(.insideTuplet(at: baseLocation)) }
        let srcTicks = target.duration.ticks(division: division)
        let dstTicks = actualDuration.ticks(division: division)
        guard dstTicks != srcTicks else { return (voice.elements, voice.tuplets) }
        let offset = try (span.startIndex ..< idx).reduce(0) { sum, i in
            guard case let .chord(member) = voice.elements[i] else {
                throw refuse(.blockedByUntimedElement(at: baseLocation.withElementIndex(i)))
            }
            return sum + member.duration.ticks(division: division)
        }

        var changed = voice
        var updated = mutated
        updated.duration = actualDuration
        changed.replaceElement(at: idx, with: .chord(updated), id: voice.elements.eid(at: idx))
        var elements = changed.elements
        var newEnd = span.endIndex

        if dstTicks < srcTicks {
            guard let pieces = scale.pieces(
                actualTicks: srcTicks - dstTicks, startingAt: offset + dstTicks,
            ) else { throw refuse(.insideTuplet(at: baseLocation)) }
            elements.insert(contentsOf: pieces.map { (ids.next(), .rest(duration: $0)) }, at: idx + 1)
            newEnd += pieces.count
        } else if dstTicks > srcTicks {
            let needed = dstTicks - srcTicks
            var consumed = 0
            var lastConsumed = idx
            var partial = 0
            var i = idx + 1
            while i <= span.endIndex, consumed < needed {
                guard case let .chord(member) = voice.elements[i] else {
                    throw refuse(.blockedByUntimedElement(at: baseLocation.withElementIndex(i)))
                }
                let ticks = member.duration.ticks(division: division)
                partial = max(0, consumed + ticks - needed)
                consumed = min(needed, consumed + ticks)
                lastConsumed = i
                i += 1
            }
            guard consumed == needed else {
                throw refuse(.insufficientRoom(neededTicks: needed, availableTicks: consumed))
            }
            var pieces: [VoiceElement] = []
            if partial > 0 {
                guard let durations = scale.pieces(actualTicks: partial, startingAt: offset + dstTicks) else {
                    throw refuse(.insideTuplet(at: baseLocation))
                }
                if case let .chord(overshot) = voice.elements[lastConsumed], !overshot.notes.isEmpty {
                    pieces = DurationChangeAlgorithm.makeChordChain(
                        from: overshot, durations: durations, onsetOwnership: .allContinuation,
                    )
                } else {
                    pieces = durations.map { .rest(duration: $0) }
                }
            }
            elements.removeSubrange((idx + 1) ..< (lastConsumed + 1))
            elements.insert(contentsOf: pieces.map { (ids.next(), $0) }, at: idx + 1)
            newEnd += pieces.count - (lastConsumed - idx)
        }

        var tuplets = changed.tuplets
        let lastMember = elements.eid(at: newEnd)
        tuplets.updateValue(at: spanIndex) { $0.last = .element(lastMember) }
        return (elements, tuplets)
    }

    /// Converts between a tuplet's written lengths and the actual ticks its members take.
    private struct Scale {
        let normal: Int
        let actualNotes: Int
        let division: Int

        init(normal: Int, actual: Int, division: Int) {
            self.normal = normal
            actualNotes = actual
            self.division = division
        }

        /// The member length `written` occupies: `written × normal / actual`, spelled as the decoder spells it.
        /// `nil` when that is not a whole number of ticks.
        func actual(_ written: NoteDuration) -> NoteDuration? {
            if case .measure = written { return nil }
            let fraction = written.asFraction
            let scaled = Fraction(
                numerator: fraction.numerator * normal, denominator: fraction.denominator * actualNotes,
            )
            guard (scaled.numerator * division * 4) % scaled.denominator == 0 else { return nil }
            return .fraction(scaled)
        }

        /// Beat-aligned member lengths for a gap of `actualTicks` that starts `startingAt` ticks into the tuplet,
        /// aligned in WRITTEN time — the tuplet's own beat — as `alignedDurations` aligns a bar's.
        func pieces(actualTicks: Int, startingAt start: Int) -> [NoteDuration]? {
            guard let length = writtenTicks(actualTicks), let offset = writtenTicks(start) else { return nil }
            let writtenPieces = DurationChangeAlgorithm.alignedDurations(
                forTicks: length, rtickStart: offset, division: division,
            )
            let scaled = writtenPieces.compactMap { actual($0) }
            return scaled.count == writtenPieces.count ? scaled : nil
        }

        private func writtenTicks(_ actualTicks: Int) -> Int? {
            let product = actualTicks * actualNotes
            return product % normal == 0 ? product / normal : nil
        }
    }
}
