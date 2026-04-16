#if os(macOS)
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, *)
extension LayoutEngine {
    /// Place elements of a measure in local measure coordinates.
    /// Returns the placed elements + the updated clef context.
    ///
    /// Layout strategy: non-timed leading elements (clef / key sig / time
    /// sig) are stacked left-to-right at fixed widths. Timed elements
    /// (chords and rests) are then positioned proportionally to their
    /// tick offset within the measure so the content fills the full
    /// stretched measure width.
    static func placeMeasureElements(
        measure: Measure,
        width: CGFloat,
        metrics: StaffMetrics,
        activeClef: NotatedClef,
        initialClefRawType: String? = nil,
        headerSchedule: HeaderSchedule,
        division: Int
    ) -> (elements: [LayoutElement], clef: NotatedClef) {
        let staffMidY = metrics.staffHeight / 2 + metrics.sp * 2
        var out: [LayoutElement] = []
        var currentClef = activeClef

        // --- Scan: time signature and total ticks in the widest voice ---
        var measureTimeSig: TimeSignature?
        for voice in measure.voices {
            for el in voice.elements {
                if case .timeSignature(let ts) = el {
                    measureTimeSig = ts
                    break
                }
            }
            if measureTimeSig != nil { break }
        }
        // --- Should we synthesize a leading clef? ---
        //
        // MuseScore omits explicit `<Clef>` in the first measure when the
        // default is implied by the instrument (e.g. treble for voice,
        // percussion for drums). Callers pass the staff's default raw
        // type via `initialClefRawType` on the first system; if no
        // explicit `.clef(...)` leads the voice, we synthesize one so
        // the staff is readable.
        let synthesizeLeadingClef: Bool
        if let rawType = initialClefRawType,
           !firstVoiceStartsWithClef(measure: measure) {
            synthesizeLeadingClef = true
            currentClef = NotatedClef(rawType: rawType)
        } else {
            synthesizeLeadingClef = false
        }

        // Content width uses the shared schedule, so timed elements in
        // this staff align with timed elements in every other staff of
        // the same system.
        let trailingGap = metrics.sp * 3
        let contentWidth = max(
            metrics.sp * 4,
            width - headerSchedule.contentStartX - trailingGap)

        // --- Pass 2: emit elements for each voice ---
        var remainingSynthClef = synthesizeLeadingClef
        for voice in measure.voices {
            let voiceTotal = totalTicks(in: voice, division: division)
            var tickCursor = 0
            var inHeader = true
            var voiceChordOutIndex: [Int: Int] = [:]

            // Emit the synthesized leading clef exactly once, at the top
            // of the first voice to process it.
            if remainingSynthClef, let rawType = initialClefRawType {
                out.append(.clef(
                    rawType: rawType,
                    origin: CGPoint(
                        x: headerSchedule.clefX, y: staffMidY)))
                remainingSynthClef = false
            }

            /// x-coordinate for the next timed element based on tick.
            func timedX() -> CGFloat {
                guard voiceTotal > 0 else {
                    return headerSchedule.contentStartX + metrics.sp
                }
                let fraction = CGFloat(tickCursor) / CGFloat(voiceTotal)
                return headerSchedule.contentStartX
                    + metrics.sp + fraction * contentWidth
            }

            for (voiceIdx, el) in voice.elements.enumerated() {
                switch el {
                case .clef(let clef):
                    currentClef = NotatedClef(rawType: clef.concertClefType)
                    let clefX = inHeader ? headerSchedule.clefX : timedX()
                    out.append(.clef(
                        rawType: clef.concertClefType,
                        origin: CGPoint(x: clefX, y: staffMidY)))
                case .keySignature(let key):
                    let keyX = inHeader ? headerSchedule.keySigX : timedX()
                    out.append(.keySignature(
                        sharps: max(0, key.concertKey),
                        flats: max(0, -key.concertKey),
                        origin: CGPoint(x: keyX, y: staffMidY)))
                case .timeSignature(let ts):
                    let tsX = inHeader ? headerSchedule.timeSigX : timedX()
                    out.append(.timeSignature(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                        origin: CGPoint(x: tsX, y: staffMidY)))
                case .barLine(let b):
                    let barX = inHeader ? metrics.sp : timedX()
                    out.append(.barLine(
                        subtype: b.subtype,
                        origin: CGPoint(x: barX, y: staffMidY)))
                case .rest(let r):
                    inHeader = false
                    out.append(.rest(
                        duration: r.duration,
                        origin: CGPoint(x: timedX(), y: staffMidY)))
                    tickCursor += r.duration.ticks(division: division)
                case .chord(let chord):
                    inHeader = false
                    let chordX = timedX()
                    let chordNotes = chord.notes.map { note -> LayoutChordNote in
                        let step = PitchStaffPosition.step(
                            midiPitch: note.pitch, tpc: note.tpc,
                            clef: currentClef
                        ).step
                        let y = staffMidY - CGFloat(step) * metrics.sp / 2
                        return LayoutChordNote(
                            step: step,
                            accidental: note.accidental,
                            origin: CGPoint(x: chordX, y: y),
                            tieForward: note.tieForward,
                            tieBack: note.tieBack,
                            hasGlissando: note.glissando != nil
                        )
                    }
                    let stem = StemDirectionRule.direction(
                        for: chordNotes.map(\.step))
                    voiceChordOutIndex[voiceIdx] = out.count
                    out.append(.chord(
                        notes: chordNotes,
                        duration: chord.duration,
                        stem: stem,
                        stemOrigin: CGPoint(x: chordX, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: chord.arpeggio.flatMap(arpeggioSubtype),
                        isBeamed: false))
                    if let arp = chord.arpeggio {
                        let ys = chordNotes.map(\.origin.y)
                        let top = ys.min() ?? staffMidY
                        let bot = ys.max() ?? staffMidY
                        out.append(.arpeggioWiggle(
                            top: CGPoint(x: chordX, y: top),
                            bottom: CGPoint(x: chordX, y: bot),
                            subtype: arpeggioSubtype(arp)
                        ))
                    }
                    tickCursor += chord.duration.ticks(division: division)
                case .dynamic(let d):
                    // Dynamics sit below-left of the note they apply to
                    // (i.e. the next timed element at the current tick).
                    // Shift 1 sp left so the label doesn't overlap the
                    // following chord's notehead or stem.
                    let baseX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX()
                    out.append(.textMark(
                        kind: .dynamic,
                        text: d.subtype,
                        origin: CGPoint(
                            x: baseX - metrics.sp,
                            y: staffMidY + metrics.sp * 4)))
                case .tempo(let t):
                    let bpm = Int((t.beatsPerSecond * 60.0).rounded())
                    // "♩" is Unicode U+2669, rendered in the system text font,
                    // not a SMuFL/Bravura glyph — do not migrate to a SMuFL
                    // codepoint without also switching the renderer's font.
                    let tempoX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX()
                    out.append(.textMark(
                        kind: .tempo,
                        text: "♩ = \(bpm)",
                        origin: CGPoint(
                            x: tempoX,
                            y: staffMidY - metrics.sp * 4)))
                case .fermata(let f):
                    // Fermata attaches to the preceding chord/rest; emit at
                    // the last placed timed x (or header cursor if still in
                    // header, though that's unusual).
                    let lastChordX = lastChordOrRestX(in: out)
                        ?? (inHeader
                            ? headerSchedule.contentStartX
                            : timedX())
                    out.append(.fermata(
                        subtype: f.subtype,
                        origin: CGPoint(
                            x: lastChordX,
                            y: staffMidY - metrics.sp * 3)))
                case .measureRepeat:
                    out.append(.measureRepeat(
                        count: 1,
                        origin: CGPoint(x: width / 2, y: staffMidY)))
                case .spanner:
                    // Resolved at system level in the spanner-attach pass.
                    break
                }
            }

            // Glissando emission pass: pair each glissando-bearing chord
            // with the next chord in the same voice.
            let chordVoiceIndices = voiceChordOutIndex.keys.sorted()
            for (pairIdx, voiceIdx) in chordVoiceIndices.enumerated() {
                guard case .chord(let chord) = voice.elements[voiceIdx] else {
                    continue
                }
                guard let gliss = chord.notes
                    .first(where: { $0.glissando != nil })?
                    .glissando else { continue }
                let nextPairIdx = pairIdx + 1
                guard nextPairIdx < chordVoiceIndices.count else { continue }
                let nextVoiceIdx = chordVoiceIndices[nextPairIdx]
                guard let fromOutIdx = voiceChordOutIndex[voiceIdx],
                      let toOutIdx = voiceChordOutIndex[nextVoiceIdx] else {
                    continue
                }
                guard case .chord(_, _, _, let fromStem, _, _, _) =
                        out[fromOutIdx],
                      case .chord(_, _, _, let toStem, _, _, _) =
                        out[toOutIdx] else {
                    continue
                }
                out.append(.glissandoLine(
                    fromOrigin: fromStem,
                    toOrigin: toStem,
                    wavy: gliss.visualType == .wavy,
                    text: gliss.text
                ))
            }

            // Beaming pass for this voice.
            let groups = beamGroups(
                voice: voice,
                timeSignature: measureTimeSig,
                division: division)
            for group in groups {
                // --- Phase 1: collect all note steps for direction ---
                var groupSteps: [Int] = []
                for memberIdx in group.memberIndices {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case .chord(let n, _, _, _, _, _, _)
                            = out[outIdx]
                    else { continue }
                    groupSteps.append(contentsOf: n.map(\.step))
                }
                guard groupSteps.count >= 2 else { continue }
                let groupDirection = StemDirectionRule.direction(
                    for: groupSteps)
                let stemSideDx: CGFloat = metrics.sp * 0.59
                    * (groupDirection == .up ? 1 : -1)

                // --- Phase 2: per-member anchor info + levels ---
                var memberStemXs: [CGFloat] = []
                var anchorSteps: [Int] = []
                var anchorYs: [CGFloat] = []
                var memberLevels: [Int] = []
                for memberIdx in group.memberIndices {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case .chord(let n, _, _, let so, _, _, _)
                            = out[outIdx]
                    else {
                        memberLevels.append(0)
                        continue
                    }
                    memberStemXs.append(so.x + stemSideDx)
                    let anchorStep: Int
                    let anchorY: CGFloat
                    if groupDirection == .up {
                        anchorStep = n.map(\.step).max() ?? 0
                        anchorY = n.map(\.origin.y).min() ?? so.y
                    } else {
                        anchorStep = n.map(\.step).min() ?? 0
                        anchorY = n.map(\.origin.y).max() ?? so.y
                    }
                    anchorSteps.append(anchorStep)
                    anchorYs.append(anchorY)
                    if case .chord(let c) = voice.elements[memberIdx] {
                        memberLevels.append(beamLevel(c.duration))
                    } else {
                        memberLevels.append(0)
                    }
                }
                guard memberStemXs.count >= 2 else { continue }

                // --- Phase 3: sloped beam line ---
                let line = computeBeamLine(
                    anchorSteps: anchorSteps,
                    anchorYs: anchorYs,
                    stemXs: memberStemXs,
                    direction: groupDirection,
                    metrics: metrics)
                let beamStartX = memberStemXs.first!
                let beamEndX = memberStemXs.last!
                let beamSpan = beamEndX - beamStartX
                func beamYAt(_ x: CGFloat) -> CGFloat {
                    guard beamSpan > 0 else { return line.startY }
                    let t = (x - beamStartX) / beamSpan
                    return line.startY + (line.endY - line.startY) * t
                }
                let memberStemYs = memberStemXs.map(beamYAt)

                // --- Phase 4: rewrite each chord with its own beam y ---
                for (i, memberIdx) in group.memberIndices.enumerated() {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case .chord(let n, let d, _, let so,
                                      let arp, let art, _) = out[outIdx]
                    else { continue }
                    out[outIdx] = .chord(
                        notes: n,
                        duration: d,
                        stem: groupDirection,
                        stemOrigin: CGPoint(
                            x: so.x, y: memberStemYs[i]),
                        hasArpeggio: arp,
                        arpeggioRawType: art,
                        isBeamed: true)
                }

                // --- Phase 5: emit per-level beam runs ---
                let maxLvl = memberLevels.max() ?? 0
                guard maxLvl >= 1 else { continue }
                for lvl in 1...maxLvl {
                    var runStart: Int?
                    for i in 0..<memberLevels.count {
                        let hasThisLevel = memberLevels[i] >= lvl
                        if hasThisLevel && runStart == nil {
                            runStart = i
                        } else if !hasThisLevel, let start = runStart {
                            emitBeamRun(
                                start: start, end: i - 1,
                                level: lvl,
                                memberStemXs: memberStemXs,
                                memberStemYs: memberStemYs,
                                memberCount: memberLevels.count,
                                beamYAt: beamYAt,
                                direction: groupDirection,
                                metrics: metrics,
                                out: &out)
                            runStart = nil
                        }
                    }
                    if let start = runStart {
                        emitBeamRun(
                            start: start,
                            end: memberLevels.count - 1,
                            level: lvl,
                            memberStemXs: memberStemXs,
                            memberStemYs: memberStemYs,
                            memberCount: memberLevels.count,
                            beamYAt: beamYAt,
                            direction: groupDirection,
                            metrics: metrics,
                            out: &out)
                    }
                }
            }
        }

        // Trailing bar line if no voice emitted one.
        let hasExplicitBar = out.contains {
            if case .barLine = $0 { true } else { false }
        }
        if !hasExplicitBar {
            out.append(.barLine(
                subtype: nil,
                origin: CGPoint(
                    x: width - metrics.sp / 2,
                    y: staffMidY)))
        }
        return (out, currentClef)
    }

    /// Extract a render-ready subtype string from the Core `Arpeggio` value.
    /// `Arpeggio.subtype` is MuseScore's mscx integer code
    /// (0=NORMAL, 1=UP, 2=DOWN, 3=UP_STRAIGHT, 4=DOWN_STRAIGHT, 5=BRACKET).
    /// `ArpeggioRenderer` consumes "up" / "down" / nil — map accordingly.
    static func arpeggioSubtype(_ arp: Arpeggio) -> String? {
        switch arp.subtype {
        case 1, 3: return "up"
        case 2, 4: return "down"
        default: return nil
        }
    }

    // MARK: - Placement helpers

    /// Width consumed by the leading header (clef / key sig / time sig)
    /// of the first voice that has such elements. Measured from the left
    /// padding, inclusive of `startPadding`.
    private static func headerWidth(
        measure: Measure,
        metrics: StaffMetrics,
        startPadding: CGFloat
    ) -> CGFloat {
        var w = startPadding
        let voice = measure.voices.first
        guard let elements = voice?.elements else { return w }
        for el in elements {
            switch el {
            case .clef: w += metrics.sp * 3
            case .keySignature(let k):
                w += metrics.sp * (CGFloat(abs(k.concertKey)) + 1.5)
            case .timeSignature: w += metrics.sp * 3
            case .chord, .rest:
                return w   // first timed element ends the header
            default:
                continue
            }
        }
        return w
    }

    /// Emit a single beam bar for a run of consecutive members that
    /// share the given level. Multi-member runs span from the first
    /// member's stem tip to the last's; single-member runs become a
    /// partial stub pointing back toward the neighbour (or forward if
    /// the lone member is first in the group). All endpoints are
    /// anchored to the sloped beam line via `beamYAt` so sloped beams
    /// keep secondary bars parallel to the primary.
    private static func emitBeamRun(
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
                    y: memberStemYs[start]),
                toOrigin: CGPoint(
                    x: memberStemXs[end],
                    y: memberStemYs[end]),
                direction: direction,
                level: level))
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
            level: level))
    }

    /// True when the first voice's first element is a `<Clef>`. Used to
    /// decide whether to synthesize an implicit opening clef.
    private static func firstVoiceStartsWithClef(
        measure: Measure
    ) -> Bool {
        guard let firstElement = measure.voices.first?.elements.first
        else { return false }
        if case .clef = firstElement { return true }
        return false
    }

    private static func totalTicks(in voice: Voice, division: Int) -> Int {
        voice.elements.reduce(0) { acc, el in
            switch el {
            case .chord(let c):
                return acc + c.duration.ticks(division: division)
            case .rest(let r):
                return acc + r.duration.ticks(division: division)
            default: return acc
            }
        }
    }

    /// Find the x coordinate of the most recently emitted chord or rest
    /// in `elements`, for positioning attached marks like fermatas.
    private static func lastChordOrRestX(
        in elements: [LayoutElement]
    ) -> CGFloat? {
        for el in elements.reversed() {
            switch el {
            case .chord(_, _, _, let origin, _, _, _):
                return origin.x
            case .rest(_, let origin):
                return origin.x
            default: continue
            }
        }
        return nil
    }
}
#endif
