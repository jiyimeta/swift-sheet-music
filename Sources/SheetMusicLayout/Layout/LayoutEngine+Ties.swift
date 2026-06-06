// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// Resolved tie arc: an absolute-coords pair ready to attach to a
    /// layout system (coordinates are system-absolute; the attach pass
    /// converts them to system-local).
    struct TiePair: Equatable {
        let staff: Int // staff index (v1 only staff 0 considered)
        let fromOrigin: CGPoint // absolute (system + measure + note origin)
        let toOrigin: CGPoint
        let above: Bool // arc curves above (true) or below (false)
    }

    /// Pair up ties across the fully-laid-out document. Walk each system's
    /// measures in order, tracking per-tie-number "open" origins. When a
    /// note with tieBack == n is seen, emit a TiePair using the matching
    /// open origin + the current note's absolute origin.
    static func resolveTies( // swiftlint:disable:this function_body_length
        for document: LayoutDocument,
        score: Score,
    ) -> [TiePair] {
        var pairs: [TiePair] = []
        // For open ties: store (origin, above) so the arc direction is
        // consistent between the start note and the end note.
        // Keyed by (tieNumber, pitch, staffIndex) — all three are
        // needed to prevent cross-staff / cross-voice mis-matching:
        //
        // - tieNumber alone collides across ALL staves.
        // - (number, pitch) collides when two staves share the same
        //   clef (e.g. two treble staves both holding C4).
        // - Adding `staffIndex` (the index of the staff within the
        //   system, derived by closest-midline match) uniquely
        //   identifies the staff in a way that is STABLE across
        //   system breaks. An earlier version used the absolute
        //   staff-midline Y, but that differs between systems in
        //   vertical / page mode (different `system.origin.y`),
        //   so a tie crossing a system break failed to match and
        //   was silently dropped.
        //
        // `pitch` (not staff step) is the discriminator so a tie whose
        // ends are spelled enharmonically differently after a transpose
        // (E♯ tied to F) still pairs — same pitch, different step.
        struct TieKey: Hashable {
            let number: Int
            let pitch: Int
            let staffIndex: Int
        }
        /// Pair ties by SOUNDING pitch, not staff step. Transpose can spell the
        /// two ends of a tie enharmonically differently across a key change
        /// (e.g. E♯ tied to F) — same pitch, different step — and a step-keyed
        /// match would silently drop such a tie. Resolve the laid-out note to
        /// its score pitch; fall back to step only if it can't be resolved
        /// (shouldn't happen for a real note).
        func tieDiscriminator(_ n: LayoutChordNote) -> Int {
            score[n.noteID]?.pitch ?? n.step
        }
        var open: [TieKey: (origin: CGPoint, above: Bool)] = [:]
        let sp = document.metrics.sp
        let staffMidOffset = document.metrics.staffHeight / 2
        for system in document.systems {
            // Per-system staff midlines (system-local). Used to pick
            // the staff INDEX a note belongs to so the discriminator
            // is identical for the same staff in any other system.
            let staffMidYsLocal = system.staffOrigins.map {
                $0.y + staffMidOffset
            }
            for measure in system.measures {
                for el in measure.elements {
                    guard case let .chord(notes, _, stem, _, _, _, _, _, _, _)
                        = el else { continue }
                    let noteSteps = notes.map(\.step)
                    let maxStep = noteSteps.max() ?? 0
                    let minStep = noteSteps.min() ?? 0
                    for n in notes {
                        // Anchor ties on the visual notehead — for
                        // mirrored notes (in seconds), the tie has to
                        // start from the side the head was pushed to,
                        // not the chord's natural anchor x.
                        let absolute = CGPoint(
                            x: system.origin.x
                                + measure.origin.x
                                + n.origin.x
                                + n.mirrorDx(stem: stem, sp: sp),
                            y: system.origin.y
                                + measure.origin.y
                                + n.origin.y,
                        )
                        // Tie direction: opposite of stem for single notes
                        // (MuseScore's primary rule). For chords: top note
                        // → above, bottom note → below, middle → opposite
                        // of stem.
                        let above: Bool
                        if maxStep == minStep {
                            // Single note in chord.
                            above = stem == .down
                        } else if n.step == maxStep {
                            above = true // top note → tie above
                        } else if n.step == minStep {
                            above = false // bottom note → tie below
                        } else {
                            above = stem == .down
                        }
                        // Find which staff this note belongs to within
                        // its system by matching its derived midline
                        // against `staffMidYsLocal`. The note's own y
                        // plus `step * sp / 2` is its staff midline in
                        // absolute coordinates; subtracting the system
                        // origin gives the system-local midline.
                        let noteMidYLocal = (absolute.y - system.origin.y)
                            + CGFloat(n.step) * sp / 2
                        var staffIndex = 0
                        var bestDist = CGFloat.infinity
                        for (i, mid) in staffMidYsLocal.enumerated() {
                            let d = abs(mid - noteMidYLocal)
                            if d < bestDist {
                                bestDist = d
                                staffIndex = i
                            }
                        }

                        if let back = n.tieBack {
                            let key = TieKey(
                                number: back, pitch: tieDiscriminator(n),
                                staffIndex: staffIndex,
                            )
                            if let openTie = open[key] {
                                pairs.append(TiePair(
                                    staff: staffIndex,
                                    fromOrigin: openTie.origin,
                                    toOrigin: absolute,
                                    above: openTie.above,
                                ))
                                open[key] = nil
                            }
                        }
                        if let fwd = n.tieForward {
                            let key = TieKey(
                                number: fwd, pitch: tieDiscriminator(n),
                                staffIndex: staffIndex,
                            )
                            open[key] = (absolute, above)
                        }
                    }
                }
            }
        }
        return pairs
    }

    static func attachTies( // swiftlint:disable:this function_body_length
        to systems: [LayoutSystem],
        pairs: [TiePair],
        metrics: StaffMetrics,
    ) -> [LayoutSystem] {
        guard !pairs.isEmpty else { return systems }

        var extraPerSystem: [[LayoutElement]] =
            Array(repeating: [], count: systems.count)

        for pair in pairs {
            let fromSysIdx = systemIndex(
                for: pair.fromOrigin.y, in: systems,
            )
            let toSysIdx = systemIndex(
                for: pair.toOrigin.y, in: systems,
            )
            if fromSysIdx == toSysIdx, let idx = fromSysIdx {
                let sys = systems[idx]
                let localFrom = CGPoint(
                    x: pair.fromOrigin.x - sys.origin.x,
                    y: pair.fromOrigin.y - sys.origin.y,
                )
                let localTo = CGPoint(
                    x: pair.toOrigin.x - sys.origin.x,
                    y: pair.toOrigin.y - sys.origin.y,
                )
                extraPerSystem[idx].append(.tieArc(
                    fromOrigin: localFrom,
                    toOrigin: localTo,
                    above: pair.above,
                ))
            } else if let from = fromSysIdx, let to = toSysIdx {
                let fromSys = systems[from]
                let toSys = systems[to]
                // BEGIN segment (end of source system): the tie hangs
                // from the source chord out to the right edge of the
                // system, mirroring MuseScore's
                // `system->endingXForOpenEndedLines()` (slurtielayout
                // line 1559). The 2 px inset keeps it off the canvas
                // edge so anti-aliasing can finish the curve.
                let edgeX = fromSys.size.width - 2
                extraPerSystem[from].append(.tieArc(
                    fromOrigin: CGPoint(
                        x: pair.fromOrigin.x - fromSys.origin.x,
                        y: pair.fromOrigin.y - fromSys.origin.y,
                    ),
                    toOrigin: CGPoint(
                        x: edgeX,
                        y: pair.fromOrigin.y - fromSys.origin.y,
                    ),
                    above: pair.above,
                ))
                // END segment (start of target system): MuseScore
                // anchors p1 at `system->firstNoteRestSegmentX(true)`
                // (slurtielayout line 1625) — the X of the first
                // note/rest in the system, NOT x=0. Anchoring at 0
                // makes the tie span across the synthesised clef and
                // key signature, which looks wrong. We approximate
                // `firstNoteRestSegmentX` by scanning the first
                // measure for the leftmost chord/rest origin and
                // backing off by half a space.
                let toLocalChordX = pair.toOrigin.x - toSys.origin.x
                let firstContent = firstContentX(in: toSys)
                let endSegStart = max(
                    firstContent - metrics.sp * 0.5,
                    toLocalChordX - metrics.sp * 4,
                )
                extraPerSystem[to].append(.tieArc(
                    fromOrigin: CGPoint(
                        x: min(
                            endSegStart,
                            toLocalChordX - metrics.sp,
                        ),
                        y: pair.toOrigin.y - toSys.origin.y,
                    ),
                    toOrigin: CGPoint(
                        x: toLocalChordX,
                        y: pair.toOrigin.y - toSys.origin.y,
                    ),
                    above: pair.above,
                ))
            }
        }

        return systems.enumerated().map { idx, system in
            LayoutSystem(
                origin: system.origin,
                size: system.size,
                measures: system.measures,
                staffOrigins: system.staffOrigins,
                staffAddresses: system.staffAddresses,
                partLabels: system.partLabels,
                brackets: system.brackets,
                spanners: system.spanners + extraPerSystem[idx],
                sp: system.sp,
                invisibleSpanners: system.invisibleSpanners,
                showsInvisibleElements: system.showsInvisibleElements,
            )
        }
    }

    /// X coordinate (system-local) of the first chord/rest in the
    /// first measure of `system`. Used as MuseScore's
    /// `firstNoteRestSegmentX` analogue when laying out the END
    /// segment of a tie at a system head: anchoring there keeps the
    /// arc clear of the synthesised clef and key signature.
    private static func firstContentX(in system: LayoutSystem) -> CGFloat {
        guard let firstMeasure = system.measures.first else { return 0 }
        var firstX: CGFloat = .infinity
        for el in firstMeasure.elements {
            switch el {
            case let .chord(notes, _, _, _, _, _, _, _, _, _):
                if let n = notes.first {
                    firstX = min(
                        firstX,
                        firstMeasure.origin.x + n.origin.x,
                    )
                }
            case let .rest(_, p, _, _, _):
                firstX = min(
                    firstX,
                    firstMeasure.origin.x + p.x,
                )
            default:
                break
            }
        }
        return firstX.isFinite ? firstX : 0
    }

    static func systemIndex(
        for absY: CGFloat, in systems: [LayoutSystem],
    ) -> Int? {
        for (i, s) in systems.enumerated() {
            if absY >= s.origin.y && absY <= s.origin.y + s.size.height {
                return i
            }
        }
        return nil
    }
}
