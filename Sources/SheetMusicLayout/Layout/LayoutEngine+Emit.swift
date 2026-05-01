// swiftlint:disable function_body_length file_length
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// Emit a `.tupletLabel` for one `Tuplet` span. Picks bracket vs
    /// number-only based on whether every member sits inside the same
    /// beam group (MuseScore's simplified auto-bracket rule).
    static func emitTupletLabel(
        tuplet: Tuplet,
        voice: Voice,
        voiceChordOutIndex: [Int: Int],
        voiceRestOutIndex: [Int: Int],
        out: inout [LayoutElement],
        beamGroups: [BeamGroup],
        staffMidY: CGFloat,
        metrics: StaffMetrics,
        tupletID: TupletID? = nil
    ) {
        // Walk every member. Chord X positions also feed the
        // Y-anchor computation; rest X positions only widen the
        // bracket span so a rest at the start or end of the
        // tuplet doesn't visually exclude itself from the bracket.
        var memberSpanXs: [CGFloat] = []
        var chordStemXs: [CGFloat] = []
        var chordAnchorYs: [CGFloat] = [] // beam-side note y (outer note)
        var chordStemsUp = 0
        var chordCount = 0
        var containsRest = false
        for idx in tuplet.startIndex ... tuplet.endIndex {
            let el = voice.elements[idx]
            switch el {
            case let .chord(c) where !c.notes.isEmpty:
                chordCount += 1
                guard let outIdx = voiceChordOutIndex[idx],
                      case let .chord(
                          notes,
                          _,
                          stem,
                          so,
                          _,
                          _,
                          _,
                          _
                      ) = out[outIdx]
                else { continue }
                memberSpanXs.append(so.x)
                chordStemXs.append(so.x)
                if stem == .up { chordStemsUp += 1 }
                let anchorY: CGFloat
                if stem == .up {
                    anchorY = notes.map(\.origin.y).min() ?? so.y
                } else {
                    anchorY = notes.map(\.origin.y).max() ?? so.y
                }
                chordAnchorYs.append(anchorY)
            case .chord:
                // Empty chord = rest.
                containsRest = true
                guard let outIdx = voiceRestOutIndex[idx],
                      case let .rest(_, origin, _, _, _) = out[outIdx]
                else { continue }
                memberSpanXs.append(origin.x)
            default:
                continue
            }
        }
        guard let fromX = memberSpanXs.first,
              let toX = memberSpanXs.last,
              !chordStemXs.isEmpty
        else { return }

        // MuseScore's bracket rule (Tuplet::calcHasBracket): hide the
        // bracket when the first AND last tuplet members sit inside
        // the SAME beam AND no member is a rest. The beam can be
        // larger than the tuplet — what matters is that both ends
        // share one continuous beam.
        let isBeamedGroup = !containsRest
            && beamGroups.contains { bg in
                bg.memberIndices.contains(tuplet.startIndex)
                    && bg.memberIndices.contains(tuplet.endIndex)
            }

        // Place the marking above stem-up groups, below stem-down.
        let isAbove = chordStemsUp * 2 >= chordCount

        // Horizontal span — first to last MEMBER's x (chord stem
        // for chords, rest origin for rests). Widening to include
        // rests prevents the bracket from collapsing inward when a
        // tuplet member is deleted to a rest.

        // Vertical position:
        // - Beamed: just above/below the beam (= stemOrigin.y for the
        //   first and last members, already sloped).
        // - Bracketed: clear of the outer anchor by stemLen + 2 sp.
        let labelPad = metrics.sp * 1.5
        let fromY: CGFloat
        let toY: CGFloat
        if isBeamedGroup {
            // Use the chord's stemOrigin.y (which IS the beam y for
            // beamed chords) as the reference line; offset outward so
            // the number sits clear of the beam.
            guard
                let firstIdx = voiceChordOutIndex[tuplet.startIndex],
                let lastIdx = voiceChordOutIndex[tuplet.endIndex],
                case let .chord(_, _, _, firstSO, _, _, _, _) = out[firstIdx],
                case let .chord(_, _, _, lastSO, _, _, _, _) = out[lastIdx]
            else { return }
            let outward: CGFloat = isAbove ? -labelPad : labelPad
            fromY = firstSO.y + outward
            toY = lastSO.y + outward
        } else {
            // Bracket sits past the outer anchor by a fixed amount.
            let extremeY: CGFloat
            if isAbove {
                extremeY = chordAnchorYs.min() ?? staffMidY
            } else {
                extremeY = chordAnchorYs.max() ?? staffMidY
            }
            let outward: CGFloat = isAbove
                ? -(metrics.defaultStemLength + labelPad)
                : (metrics.defaultStemLength + labelPad)
            fromY = extremeY + outward
            toY = fromY // flat bracket — MuseScore sometimes slopes,
            //            but a flat bracket is the common case.
        }

        // Clamp so the bracket/number never falls inside the staff
        // lines (placement-local: staff top = sp*2, bottom = sp*6).
        let staffTop = metrics.sp * 2 - metrics.sp // 1 sp above top line
        let staffBot = metrics.sp * 6 + metrics.sp // 1 sp below bot line
        let clampedFromY: CGFloat
        let clampedToY: CGFloat
        if isAbove {
            clampedFromY = min(fromY, staffTop)
            clampedToY = min(toY, staffTop)
        } else {
            clampedFromY = max(fromY, staffBot)
            clampedToY = max(toY, staffBot)
        }

        out.append(.tupletLabel(
            fromOrigin: CGPoint(x: fromX, y: clampedFromY),
            toOrigin: CGPoint(x: toX, y: clampedToY),
            text: "\(tuplet.actualNotes)",
            hasBracket: !isBeamedGroup,
            isAbove: isAbove,
            tupletID: tupletID
        ))
    }

    /// Emit a single beam bar for a run of consecutive members that
    /// share the given level. Multi-member runs span from the first
    /// member's stem tip to the last's; single-member runs become a
    /// partial stub pointing back toward the neighbour (or forward if
    /// the lone member is first in the group). All endpoints are
    /// anchored to the sloped beam line via `beamYAt` so sloped beams
    /// keep secondary bars parallel to the primary.
    static func emitBeamRun(
        start: Int,
        end: Int,
        level: Int,
        memberStemXs: [CGFloat],
        memberStemYs: [CGFloat],
        memberCount: Int,
        beamYAt: (CGFloat) -> CGFloat,
        direction: StemDirection,
        metrics: StaffMetrics,
        out: inout [LayoutElement]
    ) {
        if end > start {
            out.append(.beam(
                fromOrigin: CGPoint(
                    x: memberStemXs[start],
                    y: memberStemYs[start]
                ),
                toOrigin: CGPoint(
                    x: memberStemXs[end],
                    y: memberStemYs[end]
                ),
                direction: direction,
                level: level
            ))
            return
        }
        let stubLen = metrics.sp * 1.5
        let x = memberStemXs[start]
        let fromX: CGFloat
        let toX: CGFloat
        if start > 0 {
            fromX = x - stubLen
            toX = x
        } else if end < memberCount - 1 {
            fromX = x
            toX = x + stubLen
        } else {
            return
        }
        out.append(.beam(
            fromOrigin: CGPoint(x: fromX, y: beamYAt(fromX)),
            toOrigin: CGPoint(x: toX, y: beamYAt(toX)),
            direction: direction,
            level: level
        ))
    }

    /// True when the first voice's first element is a `<Clef>`. Used to
    /// decide whether to synthesize an implicit opening clef.
    static func firstVoiceStartsWithClef(
        measure: Measure
    ) -> Bool {
        guard let firstElement = measure.voices.first?.elements.first
        else { return false }
        if case .clef = firstElement { return true }
        return false
    }

    /// True when the first voice's leading (pre-timed-content) run
    /// contains a `<KeySig>`.  Used to skip key-signature synthesis
    /// when the measure already has an explicit one.
    static func firstVoiceHasLeadingKeySig(
        measure: Measure
    ) -> Bool {
        guard let elements = measure.voices.first?.elements else {
            return false
        }
        for el in elements {
            switch el {
            case .keySignature:
                return true
            case .chord:
                return false
            default:
                continue
            }
        }
        return false
    }

    /// Find the x coordinate of the most recently emitted chord or rest
    /// in `elements`, for positioning attached marks like fermatas.
    static func lastChordOrRestX(
        in elements: [LayoutElement]
    ) -> CGFloat? {
        for el in elements.reversed() {
            switch el {
            case let .chord(_, _, _, origin, _, _, _, _):
                return origin.x
            case let .rest(_, origin, _, _, _):
                return origin.x
            default: continue
            }
        }
        return nil
    }
}
