/// Shared mechanics for the measure-structure commands (`InsertMeasure` / `DeleteMeasure`).
enum MeasureStructure {
    /// The signature kinds that belong to the score start and travel with it when bar 1 changes identity.
    static func isLeadingSignature(_ element: VoiceElement) -> Bool {
        switch element {
        case .keySignature, .timeSignature, .clef: true
        default: false
        }
    }

    /// The run of leading signature elements at the head of `voice`'s element list.
    static func leadingSignaturePrefix(of voice: Voice) -> [VoiceElement] {
        Array(voice.elements.prefix(while: isLeadingSignature))
    }

    /// Builds bar 0's merged leading-signature run in MuseScore's structural order — clef, then key
    /// signature, then time signature — regardless of which bar contributed which kind
    /// (`src/engraving/dom/masterscore.cpp`: signatures live in typed segments whose tick-0 order is
    /// Clef → KeySig → TimeSig, so a merge can never reproduce insertion order). `incoming`'s own
    /// declaration of a kind always wins over `deleted`'s — a bar that already declares its own key/time/
    /// clef never inherits that kind from the deleted bar.
    static func mergedLeadingSignatures(
        inheritingFrom deleted: [VoiceElement], into incoming: [VoiceElement],
    ) -> [VoiceElement] {
        func resolve(_ matches: (VoiceElement) -> Bool) -> VoiceElement? {
            incoming.first(where: matches) ?? deleted.first(where: matches)
        }
        return [
            resolve { if case .clef = $0 { true } else { false } },
            resolve { if case .keySignature = $0 { true } else { false } },
            resolve { if case .timeSignature = $0 { true } else { false } },
        ].compactMap(\.self)
    }

    /// Shifts every tuplet's `startIndex`/`endIndex` in `voice` by `delta` — used whenever elements are
    /// spliced at the head of a voice's element list (the bar-0 signature move on insert, or the
    /// signature re-home on delete), so tuplet ranges keep pointing at the same notes. Mirrors the remap
    /// convention `CreateTuplet` uses for its own splice.
    static func shiftTuplets(in voice: inout Voice, by delta: Int) {
        guard delta != 0 else { return }
        for index in voice.tuplets.indices {
            voice.tuplets[index].startIndex += delta
            voice.tuplets[index].endIndex += delta
        }
    }

    /// Remaps `tuplets` across a splice that replaced the elements up to and including old index `spliceEnd`
    /// with a run of a different length: every tuplet that starts strictly AFTER `spliceEnd` moves by `delta`,
    /// and every tuplet that starts before it is left alone. The mid-list counterpart of
    /// `shiftTuplets(in:by:)`, which shifts the whole list because its splice is always a prefix.
    ///
    /// A tuplet that OVERLAPS the splice is not a case this can answer — its members' lengths are the tuplet's
    /// to decide, so a command must refuse such a splice rather than re-spell it. Both callers do:
    /// `SplitRest` through `ensureNotInsideTuplet`, `MoveToVoice` through `.destinationNotFree`.
    static func shiftTuplets(_ tuplets: [Tuplet], by delta: Int, after spliceEnd: Int) -> [Tuplet] {
        guard delta != 0 else { return tuplets }
        return tuplets.map { tuplet in
            guard tuplet.startIndex > spliceEnd else { return tuplet }
            var shifted = tuplet
            shifted.startIndex += delta
            shifted.endIndex += delta
            return shifted
        }
    }

    /// Removes every element `shouldRemove` accepts from `voice`, remapping each tuplet endpoint past the
    /// removals that preceded it so tuplet ranges keep pointing at the same elements. `shiftTuplets(in:by:)`
    /// is the special case where the removals form a uniform prefix; this is the general one, for removals
    /// that can fall anywhere in the list (a mid-bar key change, say).
    ///
    /// Endpoints are assumed to name surviving elements — a tuplet always spans chords/rests, never a
    /// signature — so a removed endpoint is not a case that needs a policy here.
    static func removeElements(
        in voice: inout Voice, where shouldRemove: (VoiceElement) -> Bool,
    ) {
        // `removedBefore[i]` = removals strictly before old index `i`, so a survivor at `i` lands on
        // `i - removedBefore[i]`. Sized `count + 1` so an inclusive end index one past the last element
        // (an empty voice's degenerate tuplet) still resolves.
        var removedBefore: [Int] = []
        removedBefore.reserveCapacity(voice.elements.count + 1)
        var removed = 0
        for element in voice.elements {
            removedBefore.append(removed)
            if shouldRemove(element) { removed += 1 }
        }
        removedBefore.append(removed)
        guard removed > 0 else { return }
        voice.elements.removeAll(where: shouldRemove)
        for index in voice.tuplets.indices {
            let start = voice.tuplets[index].startIndex
            let end = voice.tuplets[index].endIndex
            if removedBefore.indices.contains(start) {
                voice.tuplets[index].startIndex = start - removedBefore[start]
            }
            if removedBefore.indices.contains(end) {
                voice.tuplets[index].endIndex = end - removedBefore[end]
            }
        }
    }

    static func measureCount(of score: Score) -> Int {
        score.parts.first?.staves.first?.measures.count ?? 0
    }

    static func blankColumn(for score: Score) -> MeasureSlice {
        MeasureSlice(
            staffMeasures: score.parts.map { part in
                part.staves.map { _ in Measure(voices: [Voice(elements: [.rest(duration: .measure)])]) }
            },
            systemMeasure: SystemMeasure(),
        )
    }

    /// Spanners store a relative forward measure distance; a structural change between a spanner's anchor and its
    /// end must stretch or shrink that distance.
    static func adjustSpannerOffsets(in score: inout Score, forInsertionAt index: Int) {
        adjustSpannerOffsets(in: &score) { id, offset in
            id.measureIndex < index && index <= id.measureIndex + offset ? offset + 1 : offset
        }
    }

    /// Shrinks every spanner whose span crosses the deleted measure, and returns the addresses of the ones
    /// whose span *ended exactly at* the deleted measure (`index == anchorMeasure + offset`). Those need an
    /// exact re-increment — not the generic insertion predicate — when the deletion's inverse reinserts the
    /// column: `forInsertionAt` tests `index <= anchor + offset` against the already-shrunk offset, which
    /// no longer includes the boundary the shrink just excluded. See `DeleteMeasure.apply` / `InsertMeasure.apply`.
    @discardableResult
    static func adjustSpannerOffsets(in score: inout Score, forDeletionAt index: Int) -> [VoiceElementID] {
        var endpoints: [VoiceElementID] = []
        adjustSpannerOffsets(in: &score) { id, offset in
            guard id.measureIndex < index, index <= id.measureIndex + offset else { return offset }
            if index == id.measureIndex + offset {
                endpoints.append(id)
            }
            return offset - 1
        }
        return endpoints
    }

    private static func adjustSpannerOffsets(in score: inout Score, _ transform: (VoiceElementID, Int) -> Int) {
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                for measureIndex in score.parts[partIndex].staves[staffIndex].measures.indices {
                    for voiceIndex in score.parts[partIndex].staves[staffIndex].measures[measureIndex].voices.indices {
                        let elements = score.parts[partIndex].staves[staffIndex].measures[measureIndex]
                            .voices[voiceIndex].elements
                        for elementIndex in elements.indices {
                            guard case var .spanner(spanner) = elements[elementIndex] else { continue }
                            let id = VoiceElementID(
                                staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex),
                                measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: elementIndex,
                            )
                            spanner.nextMeasuresOffset = transform(id, spanner.nextMeasuresOffset)
                            score.parts[partIndex].staves[staffIndex].measures[measureIndex]
                                .voices[voiceIndex].elements[elementIndex] = .spanner(spanner)
                        }
                    }
                }
            }
        }
    }
}
