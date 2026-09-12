import SheetMusicFoundation

/// Where a copied stream lands: the same material, measured from a new absolute tick, cut at every measure
/// boundary it crosses.
///
/// A chord cut by a boundary becomes a tied chain (`DurationChangeAlgorithm.alignedDurations` on each side, tied
/// through), a rest becomes beat-aligned rests. A tuplet survives only when every one of its members lands inside
/// one piece — a bracket cannot span a barline, and the members still sound right without it because their stored
/// durations are sounding ticks.
enum RangeCopyPlacement {
    struct Piece {
        let measureIndex: Int
        let startTickInMeasure: Int
        let elements: [VoiceElement]
        /// Index ranges into `elements` that a carried tuplet covers.
        let tuplets: [(range: ClosedRange<Int>, normalNotes: Int, actualNotes: Int)]
    }

    /// Where a tuplet member landed, so a tuplet split across pieces (never carried) can be told apart from one
    /// that stayed together.
    private struct TupletMember {
        let measureIndex: Int
        let elementIndex: Int
    }

    /// Places every element of `stream` at `destinationTick + (its absoluteTick - sourceStartTick)`, cutting
    /// only what overhangs a destination barline.
    /// Returns `nil` when the destination runs past `geometry.totalTicks` — the caller appends bars and retries.
    static func pieces(
        of stream: RangeCopySource.Stream, at destinationTick: Int, sourceStartTick: Int,
        geometry: RangeCopyGeometry, division: Int,
    ) -> [Piece]? {
        var result: [Piece] = []
        var currentMeasure: Int?
        var currentStart = 0
        var currentElements: [VoiceElement] = []
        // Where each source tuplet's members ended up, keyed by its index into `stream.tuplets`.
        var tupletMembers: [Int: [TupletMember]] = [:]

        func flush() {
            guard let measure = currentMeasure, !currentElements.isEmpty else { return }
            result.append(Piece(
                measureIndex: measure, startTickInMeasure: currentStart, elements: currentElements, tuplets: [],
            ))
            currentElements = []
            currentMeasure = nil
        }

        for (absoluteTick, lengthTicks, element) in stream.elements {
            guard case let .chord(chord) = element else { continue }
            var cursor = destinationTick + (absoluteTick - sourceStartTick)
            var remaining = lengthTicks // resolved against the SOURCE bar by RangeCopySource
            var isFirstPart = true
            while remaining > 0 {
                guard let position = geometry.position(atAbsolute: cursor) else { return nil }
                let measureEnd = geometry.measureStarts[position.measure] + geometry.measureLength(position.measure)
                let partTicks = min(remaining, measureEnd - cursor)
                let isLastPart = partTicks == remaining
                if currentMeasure != position.measure {
                    flush()
                    currentMeasure = position.measure
                    currentStart = position.tick
                }
                let startIndex = currentElements.count
                if isFirstPart, isLastPart {
                    // The whole element fits here: copy it verbatim, stored duration and all. Decomposing it
                    // would un-dot a dotted note and shred a tuplet member.
                    currentElements.append(wholeBarRestSpelling(
                        of: element, at: position, length: partTicks, geometry: geometry,
                    ))
                } else {
                    currentElements.append(contentsOf: cutPieces(
                        of: chord, ticks: partTicks, rtickStart: position.tick, division: division,
                        isHead: isFirstPart, endsElement: isLastPart,
                    ))
                }
                for (tupletIndex, tuplet) in stream.tuplets.enumerated()
                    where tuplet.startTick <= absoluteTick && absoluteTick < tuplet.endTick
                {
                    tupletMembers[tupletIndex, default: []].append(
                        contentsOf: (startIndex ..< currentElements.count).map {
                            TupletMember(measureIndex: position.measure, elementIndex: $0)
                        },
                    )
                }
                cursor += partTicks
                remaining -= partTicks
                isFirstPart = false
            }
        }
        flush()
        attachTuplets(tupletMembers, of: stream, to: &result)
        return result.isEmpty ? nil : result
    }

    /// Returns `element` unchanged, except that a rest starting at tick 0 and covering the whole destination bar
    /// comes back as `.rest(duration: .measure)` — the spelling `DeleteRange`'s collapse produces and the MSCX
    /// encoder expects. `alignedDurations` would give a half plus a quarter in 3/4 instead.
    private static func wholeBarRestSpelling(
        of element: VoiceElement, at position: ScoreTickPosition, length: Int, geometry: RangeCopyGeometry,
    ) -> VoiceElement {
        guard element.isRest, position.tick == 0, length == geometry.measureLength(position.measure) else {
            return element
        }
        return .rest(duration: .measure)
    }

    /// The overhang path: `chord` is being cut into `ticks` worth of material starting at `rtickStart` within the
    /// destination measure. `isHead` marks the call that carries the source chord's own onset; `endsElement`
    /// marks the call that reaches the far end of the whole (possibly multi-piece) element. Every piece besides
    /// the true head ties back to what came before it, and every piece besides the true tail ties forward to
    /// more material — `isHead` and `endsElement` are never both true, since a fully-fitting element never
    /// reaches this helper.
    private static func cutPieces(
        of chord: Chord, ticks: Int, rtickStart: Int, division: Int, isHead: Bool, endsElement: Bool,
    ) -> [VoiceElement] {
        guard !chord.notes.isEmpty else {
            return DurationChangeAlgorithm.alignedRests(forTicks: ticks, rtickStart: rtickStart, division: division)
        }
        let durations = DurationChangeAlgorithm.alignedDurations(
            forTicks: ticks, rtickStart: rtickStart, division: division,
        )
        guard !durations.isEmpty else { return [] }

        var pieces: [VoiceElement]
        if isHead {
            var head = chord
            head.duration = durations[0]
            pieces = [settingTie(.chord(head), forward: 1)]
            let continuationDurations = Array(durations.dropFirst())
            if !continuationDurations.isEmpty {
                pieces += DurationChangeAlgorithm.makeChordChain(
                    from: chord, durations: continuationDurations, onsetOwnership: .allContinuation,
                )
            }
        } else {
            pieces = DurationChangeAlgorithm.makeChordChain(
                from: chord, durations: durations, onsetOwnership: .allContinuation,
            )
        }

        // Every piece but the true head of the element is a continuation, so it always ties back to what came
        // before it — `makeChordChain` only knows about ITS OWN slice and clears `tieBack` on its own first piece.
        let firstContinuationIndex = isHead ? 1 : 0
        if pieces.indices.contains(firstContinuationIndex) {
            pieces[firstContinuationIndex] = settingTie(pieces[firstContinuationIndex], back: 1)
        }
        // The last piece produced here ties forward to more material unless this call reaches the true end.
        if !endsElement, let lastIndex = pieces.indices.last {
            pieces[lastIndex] = settingTie(pieces[lastIndex], forward: 1)
        }
        return pieces
    }

    /// Sets `tieBack` and/or `tieForward` to `back`/`forward` on every note of a chord element. A `nil` argument
    /// leaves that side of the tie as the element already has it.
    private static func settingTie(_ element: VoiceElement, back: Int? = nil, forward: Int? = nil) -> VoiceElement {
        settingTie(chordOf: element) { chord in
            for index in chord.notes.indices {
                chord.notes.updateNote(at: index) {
                    if let back { $0.tieBack = back }
                    if let forward { $0.tieForward = forward }
                }
            }
        }
    }

    private static func settingTie(chordOf element: VoiceElement, _ transform: (inout Chord) -> Void) -> VoiceElement {
        guard case var .chord(chord) = element else { return element }
        transform(&chord)
        return .chord(chord)
    }

    /// Keeps a tuplet only when every recorded member shares one destination measure, converting its member
    /// indices into the `ClosedRange<Int>` each `Piece` carries. Ticks always advance, so a stream never revisits
    /// a measure once it has left it — a given measure index owns at most one `Piece`.
    private static func attachTuplets(
        _ tupletMembers: [Int: [TupletMember]], of stream: RangeCopySource.Stream, to result: inout [Piece],
    ) {
        for (tupletIndex, members) in tupletMembers.sorted(by: { $0.key < $1.key }) {
            guard stream.tuplets.indices.contains(tupletIndex), let firstMeasure = members.first?.measureIndex,
                  members.allSatisfy({ $0.measureIndex == firstMeasure }),
                  let pieceIndex = result.firstIndex(where: { $0.measureIndex == firstMeasure })
            else { continue }
            let indices = members.map(\.elementIndex)
            guard let low = indices.min(), let high = indices.max() else { continue }
            let tuplet = stream.tuplets[tupletIndex]
            let piece = result[pieceIndex]
            result[pieceIndex] = Piece(
                measureIndex: piece.measureIndex, startTickInMeasure: piece.startTickInMeasure,
                elements: piece.elements,
                tuplets: piece.tuplets + [(
                    range: low ... high,
                    normalNotes: tuplet.normalNotes,
                    actualNotes: tuplet.actualNotes,
                )],
            )
        }
    }
}
