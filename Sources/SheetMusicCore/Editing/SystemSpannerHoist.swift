import SheetMusicFoundation

extension PositionedSystemElement {
    /// A score-wide mark — a tempo, a rehearsal mark, a system text, a system swing — written on the top staff, or on
    /// no staff, which means the top one. MuseScore's `EngravingItem::isTopSystemObject` (a system item on track 0):
    /// what `Score::sortStaves` leaves on track 0 when it renumbers every other track, so the mark stays on whichever
    /// staff is on top after a part moves. `MovePart` asks it for the same reason.
    var isTopSystemObject: Bool {
        isScoreWide && (originalStaff ?? Score.canonicalStaff) == Score.canonicalStaff
    }
}

/// Keeps the two spanners MuseScore treats as system objects — a volta and a gradual tempo change — on the top staff
/// across the structural edits that change which staff that is, beside `MeasureFlagsHoist`, which does the same for
/// the measure flags. Both live in the top staff's voices rather than in the system lane (`SpannerPlacement` writes a
/// volta at the head of `Score.canonicalStaff`'s bar), so without this pass a part moved off the top took the score's
/// repeat endings and its rit. lines with it, and removing the top part deleted them. MuseScore skips a top system
/// spanner when `Score::sortStaves` renumbers tracks, so it stays on track 0.
///
/// The callers capture both staves whole before the pass, so their inverses restore exactly what was there — the
/// placement below is deterministic, but a file can carry a volta somewhere other than where this puts one.
enum SystemSpannerHoist {
    /// Whether `element` is a system spanner — the kinds `LayoutEngine`'s empty-staff hiding also treats as system
    /// objects (`EmptyStaffHiding.isSystemSpanner`).
    static func isSystemSpanner(_ element: VoiceElement) -> Bool {
        guard case let .spanner(spanner) = element else { return false }
        return spanner.kind == .volta || spanner.kind == .gradualTempoChange
    }

    /// Moves every volta and gradual tempo change written on `source` onto `destination`, bar by bar.
    ///
    /// A volta goes to the head of the destination bar's first voice, where `SpannerPlacement` writes one. A gradual
    /// tempo change goes immediately before the chord or rest the destination starts at its tick, in the first voice
    /// that starts one there; where none does, it stays on `source`, since there is nothing to hang it on. A spanner
    /// the destination bar already carries, equal, is not doubled — the source's copy is dropped. Each moved element
    /// keeps its identifier, or is given one from `ids` when it never had one.
    static func move(
        from source: StaffAddress, to destination: StaffAddress, in score: inout Score, ids: inout EIDAllocator,
    ) {
        guard source != destination, let sourceStaff = score[source], let destinationStaff = score[destination]
        else { return }
        let sourceDurations = sourceStaff.measures.effectiveMeasureDurations()
        let destinationDurations = destinationStaff.measures.effectiveMeasureDurations()
        for measureIndex in sourceStaff.measures.indices where destinationDurations.indices.contains(measureIndex) {
            let ref = MeasureRef(measureIndex: measureIndex)
            guard var from = score[measure: ref, staff: source], var into = score[measure: ref, staff: destination],
                  from.voices.contains(where: { $0.elements.contains(where: isSystemSpanner) })
            else { continue }
            var taken: [(voiceIndex: Int, elementIndex: Int)] = []
            var voltasPlaced = 0
            for voiceIndex in from.voices.indices {
                let elements = from.voices[voiceIndex].elements
                var tick = 0
                for elementIndex in elements.indices {
                    let element = elements[elementIndex]
                    defer {
                        tick += element.cursorAdvance(
                            division: score.division, in: sourceDurations[measureIndex],
                        )
                    }
                    guard isSystemSpanner(element), case let .spanner(spanner) = element else { continue }
                    if into.voices.contains(where: { $0.elements.contains(element) }) {
                        taken.append((voiceIndex, elementIndex))
                        continue
                    }
                    let slot: (voice: Int, index: Int)? = if spanner.kind == .volta {
                        into.voices.isEmpty ? nil : (0, voltasPlaced)
                    } else {
                        chordSlot(
                            atTick: tick, in: into,
                            measureDuration: destinationDurations[measureIndex], division: score.division,
                        )
                    }
                    guard let slot else { continue }
                    let eid = elements.eid(at: elementIndex)
                    into.voices[slot.voice].elements.insert(element, at: slot.index, id: eid.isValid ? eid : ids.next())
                    if spanner.kind == .volta { voltasPlaced += 1 }
                    taken.append((voiceIndex, elementIndex))
                }
            }
            guard !taken.isEmpty else { continue }
            // Last first, so each removal leaves the indices still to remove where they were.
            for entry in taken.reversed() {
                from.voices[entry.voiceIndex].elements.removeSubrange(entry.elementIndex ..< entry.elementIndex + 1)
            }
            score[measure: ref, staff: source] = from
            score[measure: ref, staff: destination] = into
        }
    }

    /// The first voice of `measure` with a chord or rest starting at `tick`, and that element's index — where a line
    /// spanner starting there is written (`SpannerPlacement`: immediately before its start chord).
    private static func chordSlot(
        atTick tick: Int, in measure: Measure, measureDuration: Fraction, division: Int,
    ) -> (voice: Int, index: Int)? {
        for (voiceIndex, voice) in measure.voices.enumerated() {
            var running = 0
            for elementIndex in voice.elements.indices {
                let element = voice.elements[elementIndex]
                if running == tick, case .chord = element {
                    return (voiceIndex, elementIndex)
                }
                running += element.cursorAdvance(division: division, in: measureDuration)
                if running > tick { break }
            }
        }
        return nil
    }
}

extension Score {
    /// Writes `staff` over the staff at `address`, which keeps its identifier — the structural inverses' whole-staff
    /// restore. A no-op for an address the score does not have.
    mutating func replaceStaff(at address: StaffAddress, with staff: Staff) {
        guard parts.indices.contains(address.partIndex),
              parts[address.partIndex].staves.indices.contains(address.staffIndexInPart)
        else { return }
        parts.updateValue(at: address.partIndex) { part in
            part.staves.updateValue(at: address.staffIndexInPart) { $0 = staff }
        }
    }
}
