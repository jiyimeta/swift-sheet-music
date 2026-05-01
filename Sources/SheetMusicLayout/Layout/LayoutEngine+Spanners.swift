// swiftlint:disable function_body_length file_length
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// Anchor describing a Spanner's position before it has been resolved
    /// to absolute system-level coordinates.
    struct SpannerAnchor: Sendable, Equatable {
        let kind: Spanner.Kind
        let rawType: String
        let startStaff: Int
        let startMeasure: Int
        let startTick: Int
        let endStaff: Int
        let endMeasure: Int
        let endTick: Int
        let voltaEndings: [Int]
    }

    /// Walk every staff / measure / voice and collect Spanner anchors.
    /// v1 assigns `endStaff = startStaff` and `endTick = 0` (end-of-measure
    /// anchor); we refine only the `endMeasure` via `nextMeasuresOffset`.
    static func collectSpanners(score: Score) -> [SpannerAnchor] {
        var out: [SpannerAnchor] = []
        for (staffIdx, staff) in score.staves.enumerated() {
            for (measureIdx, measure) in staff.measures.enumerated() {
                for voice in measure.voices {
                    var tick = 0
                    for el in voice.elements {
                        if case let .spanner(sp) = el {
                            out.append(SpannerAnchor(
                                kind: sp.kind,
                                rawType: sp.rawType,
                                startStaff: staffIdx,
                                startMeasure: measureIdx,
                                startTick: tick,
                                endStaff: staffIdx,
                                endMeasure: measureIdx
                                    + sp.nextMeasuresOffset,
                                endTick: 0,
                                voltaEndings: sp.voltaEndings
                            ))
                        }
                        switch el {
                        case let .chord(c):
                            tick += c.duration.ticks(
                                division: score.division)
                        default: break
                        }
                    }
                }
            }
        }
        return out
    }

    static func attachSpanners(
        to systems: [LayoutSystem],
        anchors: [SpannerAnchor],
        score: Score,
        metrics: StaffMetrics
    ) -> [LayoutSystem] {
        guard !anchors.isEmpty, !systems.isEmpty else { return systems }

        // Map measure-index → (systemIdx, measureIdxInSystem).
        var measureLocation: [Int: (Int, Int)] = [:]
        var globalIdx = 0
        for (sysIdx, system) in systems.enumerated() {
            for localIdx in 0 ..< system.measures.count {
                measureLocation[globalIdx] = (sysIdx, localIdx)
                globalIdx += 1
            }
        }

        var extraPerSystem: [[LayoutElement]] =
            Array(repeating: [], count: systems.count)

        for anchor in anchors {
            guard let (startSys, startLocal) =
                measureLocation[anchor.startMeasure]
            else { continue }
            let endGlobal = max(
                anchor.startMeasure,
                min(
                    anchor.endMeasure,
                    measureLocation.keys.max() ?? anchor.startMeasure
                )
            )
            guard let (endSys, endLocal) = measureLocation[endGlobal]
            else { continue }

            let belowStaff = isBelowStaff(kind: anchor.kind)
            let kind = layoutKind(anchor: anchor)

            if startSys == endSys {
                let system = systems[startSys]
                let fromX = system.measures[startLocal].origin.x
                    + metrics.sp * 2
                let toX = system.measures[endLocal].origin.x
                    + system.measures[endLocal].width
                    - metrics.sp * 2
                let y = anchorY(
                    in: system, belowStaff: belowStaff, metrics: metrics
                )
                extraPerSystem[startSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromX, y: y),
                    toOrigin: CGPoint(x: toX, y: y),
                    continuesLeft: false,
                    continuesRight: false,
                    text: anchor.rawType
                ))
            } else {
                let startSystem = systems[startSys]
                let fromX = startSystem.measures[startLocal].origin.x
                    + metrics.sp * 2
                let toXStart = startSystem.size.width - metrics.sp * 2
                let yStart = anchorY(
                    in: startSystem, belowStaff: belowStaff,
                    metrics: metrics
                )
                extraPerSystem[startSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromX, y: yStart),
                    toOrigin: CGPoint(x: toXStart, y: yStart),
                    continuesLeft: false,
                    continuesRight: true,
                    text: anchor.rawType
                ))
                if endSys > startSys + 1 {
                    for mid in (startSys + 1) ..< endSys {
                        let midSystem = systems[mid]
                        let y = anchorY(
                            in: midSystem, belowStaff: belowStaff,
                            metrics: metrics
                        )
                        extraPerSystem[mid].append(.spannerSegment(
                            kind: kind,
                            fromOrigin: CGPoint(
                                x: metrics.sp * 2, y: y
                            ),
                            toOrigin: CGPoint(
                                x: midSystem.size.width - metrics.sp * 2,
                                y: y
                            ),
                            continuesLeft: true,
                            continuesRight: true,
                            text: anchor.rawType
                        ))
                    }
                }
                let endSystem = systems[endSys]
                let fromXEnd: CGFloat = metrics.sp * 2
                let toXEnd = endSystem.measures[endLocal].origin.x
                    + endSystem.measures[endLocal].width
                    - metrics.sp * 2
                let yEnd = anchorY(
                    in: endSystem, belowStaff: belowStaff,
                    metrics: metrics
                )
                extraPerSystem[endSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromXEnd, y: yEnd),
                    toOrigin: CGPoint(x: toXEnd, y: yEnd),
                    continuesLeft: true,
                    continuesRight: false,
                    text: anchor.rawType
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
                spanners: system.spanners + extraPerSystem[idx],
                sp: system.sp
            )
        }
    }

    static func isBelowStaff(kind: Spanner.Kind) -> Bool {
        switch kind {
        case .hairpin, .pedal: true
        default: false
        }
    }

    static func anchorY(
        in system: LayoutSystem,
        belowStaff: Bool,
        metrics: StaffMetrics
    ) -> CGFloat {
        if belowStaff {
            let last = system.staffOrigins.last ?? CGPoint(x: 0, y: 0)
            return last.y + metrics.staffHeight + metrics.sp * 3
        } else {
            let first = system.staffOrigins.first ?? CGPoint(x: 0, y: 0)
            return first.y - metrics.sp * 4
        }
    }

    static func layoutKind(
        anchor: SpannerAnchor
    ) -> LayoutElement.SpannerKind {
        switch anchor.kind {
        case .slur: return .slur
        case .volta: return .volta(endings: anchor.voltaEndings)
        case .hairpin:
            let raw = anchor.rawType.lowercased()
            if raw.contains("decr") || raw.contains("dim") {
                return .hairpinClose
            }
            return .hairpinOpen
        case .pedal: return .pedal
        case .ottava: return .ottava(raw: anchor.rawType)
        case .textLine: return .textLine
        case .glissando, .other: return .textLine
        }
    }
}
