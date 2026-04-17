#if os(macOS)
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, *)
extension LayoutEngine {
    /// Resolved tie arc: an absolute-coords pair ready to attach to a
    /// layout system (coordinates are system-absolute; the attach pass
    /// converts them to system-local).
    struct TiePair: Sendable, Equatable {
        let staff: Int            // staff index (v1 only staff 0 considered)
        let fromOrigin: CGPoint   // absolute (system + measure + note origin)
        let toOrigin: CGPoint
        let above: Bool           // arc curves above (true) or below (false)
    }

    /// Pair up ties across the fully-laid-out document. Walk each system's
    /// measures in order, tracking per-tie-number "open" origins. When a
    /// note with tieBack == n is seen, emit a TiePair using the matching
    /// open origin + the current note's absolute origin.
    static func resolveTies(
        for document: LayoutDocument,
        score: Score
    ) -> [TiePair] {
        var pairs: [TiePair] = []
        // For open ties: store (origin, above) so the arc direction is
        // consistent between the start note and the end note.
        var open: [Int: (origin: CGPoint, above: Bool)] = [:]
        for system in document.systems {
            for measure in system.measures {
                for el in measure.elements {
                    guard case .chord(let notes, _, let stem, _, _, _, _)
                        = el else { continue }
                    let noteSteps = notes.map(\.step)
                    let maxStep = noteSteps.max() ?? 0
                    let minStep = noteSteps.min() ?? 0
                    for n in notes {
                        let absolute = CGPoint(
                            x: system.origin.x
                                + measure.origin.x
                                + n.origin.x,
                            y: system.origin.y
                                + measure.origin.y
                                + n.origin.y
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
                            above = true   // top note → tie above
                        } else if n.step == minStep {
                            above = false  // bottom note → tie below
                        } else {
                            above = stem == .down
                        }
                        if let back = n.tieBack,
                           let openTie = open[back] {
                            pairs.append(TiePair(
                                staff: 0,
                                fromOrigin: openTie.origin,
                                toOrigin: absolute,
                                above: openTie.above
                            ))
                            open[back] = nil
                        }
                        if let fwd = n.tieForward {
                            open[fwd] = (absolute, above)
                        }
                    }
                }
            }
        }
        return pairs
    }

    static func attachTies(
        to systems: [LayoutSystem],
        pairs: [TiePair]
    ) -> [LayoutSystem] {
        guard !pairs.isEmpty else { return systems }

        var extraPerSystem: [[LayoutElement]] =
            Array(repeating: [], count: systems.count)

        for pair in pairs {
            let fromSysIdx = systemIndex(
                for: pair.fromOrigin.y, in: systems)
            let toSysIdx = systemIndex(
                for: pair.toOrigin.y, in: systems)
            if fromSysIdx == toSysIdx, let idx = fromSysIdx {
                let sys = systems[idx]
                let localFrom = CGPoint(
                    x: pair.fromOrigin.x - sys.origin.x,
                    y: pair.fromOrigin.y - sys.origin.y)
                let localTo = CGPoint(
                    x: pair.toOrigin.x - sys.origin.x,
                    y: pair.toOrigin.y - sys.origin.y)
                extraPerSystem[idx].append(.tieArc(
                    fromOrigin: localFrom,
                    toOrigin: localTo,
                    above: pair.above
                ))
            } else if let from = fromSysIdx, let to = toSysIdx {
                let fromSys = systems[from]
                let toSys = systems[to]
                let edgeX = fromSys.size.width - 2
                extraPerSystem[from].append(.tieArc(
                    fromOrigin: CGPoint(
                        x: pair.fromOrigin.x - fromSys.origin.x,
                        y: pair.fromOrigin.y - fromSys.origin.y),
                    toOrigin: CGPoint(
                        x: edgeX,
                        y: pair.fromOrigin.y - fromSys.origin.y),
                    above: pair.above
                ))
                extraPerSystem[to].append(.tieArc(
                    fromOrigin: CGPoint(
                        x: 0,
                        y: pair.toOrigin.y - toSys.origin.y),
                    toOrigin: CGPoint(
                        x: pair.toOrigin.x - toSys.origin.x,
                        y: pair.toOrigin.y - toSys.origin.y),
                    above: pair.above
                ))
            }
        }

        return systems.enumerated().map { idx, system in
            LayoutSystem(
                origin: system.origin,
                size: system.size,
                measures: system.measures,
                staffOrigins: system.staffOrigins,
                partLabels: system.partLabels,
                spanners: system.spanners + extraPerSystem[idx]
            )
        }
    }

    static func systemIndex(
        for absY: CGFloat, in systems: [LayoutSystem]
    ) -> Int? {
        for (i, s) in systems.enumerated() {
            if absY >= s.origin.y && absY <= s.origin.y + s.size.height {
                return i
            }
        }
        return nil
    }
}
#endif
