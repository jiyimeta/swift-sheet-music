#if os(macOS)
import CoreGraphics
import SheetMusicCore

/// Pure function: `Score` → `LayoutDocument`.
///
/// v1 is a single-pass engine with simple heuristics. No caching, no
/// mutation, no back-pointers. Safe to re-run on every option change.
@available(macOS 15.0, *)
public enum LayoutEngine {
    public static func layout(
        score: Score,
        options: ScoreViewOptions,
        availableWidth: CGFloat
    ) -> LayoutDocument {
        let metrics = StaffMetrics(staffSize: options.staffSize)
        let context = RenderContext(
            score: score,
            options: options,
            metrics: metrics,
            availableWidth: availableWidth
        )
        let systems = packSystems(context: context)
        let totalHeight = systems.reduce(CGFloat(0)) { acc, system in
            max(acc, system.origin.y + system.size.height)
        }
        let anchors = collectSpanners(score: score)
        let systemsWithSpanners = attachSpanners(
            to: systems,
            anchors: anchors,
            score: score,
            metrics: metrics
        )
        let firstPass = LayoutDocument(
            size: CGSize(width: availableWidth, height: totalHeight),
            systems: systemsWithSpanners,
            metrics: metrics
        )
        let ties = resolveTies(for: firstPass, score: score)
        let systemsWithTies = attachTies(
            to: systemsWithSpanners, pairs: ties)
        return LayoutDocument(
            size: firstPass.size,
            systems: systemsWithTies,
            metrics: metrics
        )
    }

    // MARK: - Context

    struct RenderContext {
        let score: Score
        let options: ScoreViewOptions
        let metrics: StaffMetrics
        let availableWidth: CGFloat
    }

    // MARK: - System packing

    private static func packSystems(
        context: RenderContext
    ) -> [LayoutSystem] {
        let stavesCount = context.score.staves.count
        guard stavesCount > 0,
              let firstStaff = context.score.staves.first,
              !firstStaff.measures.isEmpty else {
            return []
        }

        let measureCount = firstStaff.measures.count
        // Per-measure minimum width = max across staves so that the
        // widest staff's content fits at this index.
        let minWidths: [CGFloat] = (0..<measureCount).map { i in
            context.score.staves.map { staff in
                i < staff.measures.count
                    ? minimumMeasureWidth(
                        measure: staff.measures[i],
                        metrics: context.metrics)
                    : 0
            }.max() ?? 0
        }

        var systems: [LayoutSystem] = []
        var currentY: CGFloat = 0
        var cursor = 0
        var isFirstSystem = true
        while cursor < measureCount {
            var widthSoFar: CGFloat = 0
            let systemStart = cursor
            while cursor < measureCount {
                let w = minWidths[cursor]
                if context.options.wrapToViewWidth
                    && widthSoFar + w > context.availableWidth
                    && cursor > systemStart {
                    break
                }
                widthSoFar += w
                cursor += 1
            }
            let widthsSlice = Array(minWidths[systemStart..<cursor])
            let stretched = stretchWidths(
                widths: widthsSlice,
                availableWidth: context.availableWidth,
                shouldStretch: context.options.wrapToViewWidth
            )
            let system = buildSystem(
                measureRange: systemStart..<cursor,
                widths: stretched,
                systemOriginY: currentY,
                isFirstSystem: isFirstSystem,
                context: context
            )
            currentY += system.size.height + context.options.systemGap
            systems.append(system)
            isFirstSystem = false
        }
        return systems
    }

    private static func stretchWidths(
        widths: [CGFloat],
        availableWidth: CGFloat,
        shouldStretch: Bool
    ) -> [CGFloat] {
        let total = widths.reduce(0, +)
        guard shouldStretch, total > 0, availableWidth > total else {
            return widths
        }
        let ratio = availableWidth / total
        return widths.map { $0 * ratio }
    }

    private static func minimumMeasureWidth(
        measure: Measure,
        metrics: StaffMetrics
    ) -> CGFloat {
        let leftPadding = metrics.sp * 3
        let rightPadding = metrics.sp * 2
        var maxVoiceWidth: CGFloat = 0
        for voice in measure.voices {
            var w: CGFloat = 0
            for el in voice.elements {
                switch el {
                case .clef:
                    w += metrics.sp * 3
                case .keySignature(let k):
                    w += metrics.sp * (CGFloat(abs(k.concertKey)) + 1)
                case .timeSignature:
                    w += metrics.sp * 3
                case .barLine:
                    w += metrics.sp
                case .chord(let c):
                    w += durationWidth(c.duration, metrics: metrics)
                case .rest(let r):
                    w += durationWidth(r.duration, metrics: metrics)
                case .dynamic, .tempo, .fermata,
                     .measureRepeat, .spanner:
                    break
                }
            }
            maxVoiceWidth = max(maxVoiceWidth, w)
        }
        return leftPadding + maxVoiceWidth + rightPadding
    }

    private static func durationWidth(
        _ dur: NoteDuration, metrics: StaffMetrics
    ) -> CGFloat {
        // Linear in quarter-equivalent length, with a minimum floor so
        // very short notes (32nd, 64th) don't collapse to zero space.
        let quarters: Double
        switch dur {
        case .whole: quarters = 4
        case .half: quarters = 2
        case .quarter: quarters = 1
        case .eighth: quarters = 0.5
        case .sixteenth: quarters = 0.25
        case .thirtySecond: quarters = 0.125
        case .sixtyFourth: quarters = 0.0625
        case .oneTwentyEighth: quarters = 1.0 / 32
        case .twoFiftySixth: quarters = 1.0 / 64
        case .fraction(let f):
            quarters = Double(f.numerator) / Double(f.denominator) * 4
        }
        let base = metrics.spacePerQuarter * CGFloat(quarters)
        return max(base, metrics.sp * 2)
    }

    private static func buildSystem(
        measureRange: Range<Int>,
        widths: [CGFloat],
        systemOriginY: CGFloat,
        isFirstSystem: Bool,
        context: RenderContext
    ) -> LayoutSystem {
        let metrics = context.metrics
        let staves = context.score.staves
        // Vertical stacking: each staff gets staffHeight + 4 sp slack.
        let staffSpacing = metrics.staffHeight + metrics.sp * 4
        // First system reserves wider space for long part names.
        let partLabelWidth: CGFloat = isFirstSystem ? 80 : 30

        // Per-staff labels. Stage 5 assumes staves align 1:1 with parts;
        // multi-staff-per-part (piano grand staff) is handled the same
        // way for now — each staff gets its own label.
        let labels: [LayoutPartLabel] = staves.enumerated().map { idx, _ in
            let part = idx < context.score.parts.count
                ? context.score.parts[idx] : nil
            let text: String
            if isFirstSystem {
                text = part?.trackName
                    ?? part?.instrument.longName
                    ?? ""
            } else {
                text = part?.instrument.shortName
                    ?? part?.trackName.map { String($0.prefix(3)) }
                    ?? ""
            }
            let y = CGFloat(idx) * staffSpacing
                + metrics.sp * 2
                + metrics.staffHeight / 2
            return LayoutPartLabel(
                text: text,
                origin: CGPoint(x: 4, y: y)
            )
        }

        let staffOrigins: [CGPoint] = staves.enumerated().map { idx, _ in
            CGPoint(
                x: partLabelWidth,
                y: CGFloat(idx) * staffSpacing + metrics.sp * 2
            )
        }

        var layoutMeasures: [LayoutMeasure] = []
        var xCursor: CGFloat = partLabelWidth
        var clefs: [NotatedClef] = Array(
            repeating: .treble, count: staves.count)
        for (j, measureIdx) in measureRange.enumerated() {
            let w = widths[j]
            var aggregated: [LayoutElement] = []
            var markers: [LayoutElement] = []
            var jumps: [LayoutElement] = []
            for (staffIdx, staff) in staves.enumerated() {
                guard measureIdx < staff.measures.count else { continue }
                let m = staff.measures[measureIdx]
                let (els, newClef) = placeMeasureElements(
                    measure: m,
                    width: w,
                    metrics: metrics,
                    activeClef: clefs[staffIdx],
                    division: context.score.division
                )
                clefs[staffIdx] = newClef
                let yOffset = staffOrigins[staffIdx].y - staffOrigins[0].y
                aggregated.append(contentsOf: els.map {
                    translate(element: $0, dy: yOffset)
                })
                // Markers / jumps are collected only from the first staff
                // — they apply to the whole system at this measure, not
                // per staff. A piano grand staff repeats the same marker
                // on both staves in MSCX; we draw it once above the top
                // staff to match engraving convention.
                if staffIdx == 0 {
                    for marker in m.markers {
                        let labelText = marker.text.isEmpty
                            ? marker.label : marker.text
                        markers.append(.marker(
                            kind: marker.kind,
                            text: labelText,
                            origin: CGPoint(x: 4, y: yOffset - metrics.sp)
                        ))
                    }
                    for jump in m.jumps {
                        jumps.append(.jump(
                            text: jump.text,
                            origin: CGPoint(
                                x: w - metrics.sp * 4,
                                y: yOffset
                                    + metrics.staffHeight
                                    + metrics.sp
                            )
                        ))
                    }
                }
            }
            layoutMeasures.append(LayoutMeasure(
                origin: CGPoint(x: xCursor, y: 0),
                width: w,
                elements: aggregated,
                markers: markers,
                jumps: jumps
            ))
            xCursor += w
        }

        let totalHeight = CGFloat(staves.count) * staffSpacing
            + metrics.sp * 6
        return LayoutSystem(
            origin: CGPoint(x: 0, y: systemOriginY),
            size: CGSize(width: xCursor, height: totalHeight),
            measures: layoutMeasures,
            staffOrigins: staffOrigins,
            partLabels: labels,
            spanners: []
        )
    }

    /// Shift an element's origin(s) by a vertical offset, for stacking
    /// staves that were placed in staff-0-local coordinates.
    private static func translate(
        element: LayoutElement, dy: CGFloat
    ) -> LayoutElement {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: p.y + dy)
        }
        switch element {
        case .clef(let t, let p):
            return .clef(rawType: t, origin: shift(p))
        case .keySignature(let s, let f, let p):
            return .keySignature(sharps: s, flats: f, origin: shift(p))
        case .timeSignature(let n, let d, let p):
            return .timeSignature(
                numerator: n, denominator: d, origin: shift(p))
        case .barLine(let s, let p):
            return .barLine(subtype: s, origin: shift(p))
        case .rest(let d, let p):
            return .rest(duration: d, origin: shift(p))
        case .chord(let notes, let dur, let stem, let so, let arp, let art, let beamed):
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    step: $0.step,
                    accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward,
                    tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando
                )
            }
            return .chord(
                notes: shiftedNotes,
                duration: dur,
                stem: stem,
                stemOrigin: shift(so),
                hasArpeggio: arp,
                arpeggioRawType: art,
                isBeamed: beamed
            )
        case .textMark(let k, let t, let p):
            return .textMark(kind: k, text: t, origin: shift(p))
        case .fermata(let s, let p):
            return .fermata(subtype: s, origin: shift(p))
        case .measureRepeat(let c, let p):
            return .measureRepeat(count: c, origin: shift(p))
        case .note, .beam, .marker, .jump, .spannerSegment,
             .tieArc, .glissandoLine, .arpeggioWiggle:
            return element
        }
    }

    /// Place elements of a measure in local measure coordinates.
    /// Returns the placed elements + the updated clef context.
    private static func placeMeasureElements(
        measure: Measure,
        width: CGFloat,
        metrics: StaffMetrics,
        activeClef: NotatedClef,
        division: Int
    ) -> (elements: [LayoutElement], clef: NotatedClef) {
        let staffMidY = metrics.staffHeight / 2 + metrics.sp * 2
        var out: [LayoutElement] = []
        var x: CGFloat = metrics.sp * 2
        var currentClef = activeClef
        // Detect a time signature declared within this measure (any voice).
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
        for voice in measure.voices {
            var vx = x
            // Maps a voice-element index → index into `out` for the
            // emitted LayoutElement.chord. Used for post-hoc beam marking.
            var voiceChordOutIndex: [Int: Int] = [:]
            for (voiceIdx, el) in voice.elements.enumerated() {
                switch el {
                case .clef(let clef):
                    currentClef = NotatedClef(rawType: clef.concertClefType)
                    out.append(.clef(
                        rawType: clef.concertClefType,
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp * 3
                case .keySignature(let key):
                    out.append(.keySignature(
                        sharps: max(0, key.concertKey),
                        flats: max(0, -key.concertKey),
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp * CGFloat(abs(key.concertKey)) + metrics.sp
                case .timeSignature(let ts):
                    out.append(.timeSignature(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp * 3
                case .barLine(let b):
                    out.append(.barLine(
                        subtype: b.subtype,
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp
                case .rest(let r):
                    out.append(.rest(
                        duration: r.duration,
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp * 3
                case .chord(let chord):
                    let chordNotes = chord.notes.map { note -> LayoutChordNote in
                        let step = PitchStaffPosition.step(
                            midiPitch: note.pitch, tpc: note.tpc,
                            clef: currentClef
                        ).step
                        let y = staffMidY - CGFloat(step) * metrics.sp / 2
                        return LayoutChordNote(
                            step: step,
                            accidental: note.accidental,
                            origin: CGPoint(x: vx, y: y),
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
                        stemOrigin: CGPoint(x: vx, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: chord.arpeggio.flatMap(arpeggioSubtype),
                        isBeamed: false))
                    if let arp = chord.arpeggio {
                        let ys = chordNotes.map(\.origin.y)
                        let top = ys.min() ?? staffMidY
                        let bot = ys.max() ?? staffMidY
                        out.append(.arpeggioWiggle(
                            top: CGPoint(x: vx, y: top),
                            bottom: CGPoint(x: vx, y: bot),
                            subtype: arpeggioSubtype(arp)
                        ))
                    }
                    vx += metrics.sp * 3
                case .dynamic(let d):
                    out.append(.textMark(
                        kind: .dynamic,
                        text: d.subtype,
                        origin: CGPoint(
                            x: vx,
                            y: staffMidY + metrics.sp * 4)))
                    vx += metrics.sp * 2
                case .tempo(let t):
                    let bpm = Int((t.beatsPerSecond * 60.0).rounded())
                    // "♩" is Unicode U+2669, rendered in the system text font,
                    // not a SMuFL/Bravura glyph — do not migrate to a SMuFL
                    // codepoint without also switching the renderer's font.
                    out.append(.textMark(
                        kind: .tempo,
                        text: "♩ = \(bpm)",
                        origin: CGPoint(
                            x: vx,
                            y: staffMidY - metrics.sp * 4)))
                    vx += metrics.sp * 2
                case .fermata(let f):
                    // Fermata attaches to the preceding chord/rest (which
                    // already advanced vx), so emit at vx - sp and do NOT
                    // advance vx further.
                    out.append(.fermata(
                        subtype: f.subtype,
                        origin: CGPoint(
                            x: vx - metrics.sp,
                            y: staffMidY - metrics.sp * 3)))
                case .measureRepeat:
                    out.append(.measureRepeat(
                        count: 1,
                        origin: CGPoint(x: width / 2, y: staffMidY)))
                case .spanner:
                    // Spanners are resolved at system level in Stage 9.
                    break
                }
            }
            // Glissando emission pass: for each chord in this voice with a
            // note carrying a glissando, pair it with the next chord in the
            // same voice and emit a glissandoLine between their stemOrigins.
            // voiceChordOutIndex maps voice-element idx → out idx for the
            // chord emitted there. We iterate the voice-element indices in
            // sorted order to find consecutive chord pairs.
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
                var firstStemOrigin: CGPoint?
                var lastStemOrigin: CGPoint?
                for memberIdx in group.memberIndices {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case .chord(let n, let d, let s, let so,
                                      let arp, let art, _) = out[outIdx]
                    else { continue }
                    out[outIdx] = .chord(
                        notes: n,
                        duration: d,
                        stem: s,
                        stemOrigin: so,
                        hasArpeggio: arp,
                        arpeggioRawType: art,
                        isBeamed: true)
                    if firstStemOrigin == nil { firstStemOrigin = so }
                    lastStemOrigin = so
                }
                if let f = firstStemOrigin, let l = lastStemOrigin {
                    // Raise beam above the stem anchor so it sits near the
                    // flag position. v1: fixed offset (refined in later
                    // stages alongside stem-direction awareness).
                    let beamY = f.y - metrics.defaultStemLength
                    out.append(.beam(
                        fromOrigin: CGPoint(x: f.x, y: beamY),
                        toOrigin: CGPoint(x: l.x, y: beamY),
                        levels: group.level))
                }
            }
            x = max(x, vx)
        }
        // Trailing bar line if the voice didn't already emit one.
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

    // MARK: - Beaming

    struct BeamGroup: Sendable, Equatable {
        /// Voice-element indices (into `voice.elements`) of the chords in
        /// this beam group. Always length >= 2.
        let memberIndices: [Int]
        /// 1 = eighth-style (one beam bar), 2 = 16th (two bars), etc.
        let level: Int
    }

    /// Compute beam groups for a single voice under the given time signature.
    /// Pure function; no layout side effects.
    static func beamGroups(
        voice: Voice,
        timeSignature: TimeSignature?,
        division: Int
    ) -> [BeamGroup] {
        let beat = beatTicks(
            timeSignature: timeSignature, division: division)
        var tick = 0
        var groups: [BeamGroup] = []
        var currentIndices: [Int] = []
        var currentLevel = 0
        func flush() {
            if currentIndices.count >= 2 && currentLevel >= 1 {
                groups.append(BeamGroup(
                    memberIndices: currentIndices, level: currentLevel))
            }
            currentIndices.removeAll()
            currentLevel = 0
        }
        for (i, el) in voice.elements.enumerated() {
            switch el {
            case .chord(let c):
                let level = beamLevel(c.duration)
                if level == 0 {
                    flush()
                    tick += c.duration.ticks(division: division)
                    continue
                }
                // Flush at beat boundary BEFORE adding this chord.
                if tick > 0 && tick % beat == 0 { flush() }
                currentIndices.append(i)
                currentLevel = max(currentLevel, level)
                tick += c.duration.ticks(division: division)
            case .rest(let r):
                flush()
                tick += r.duration.ticks(division: division)
            default:
                // Clefs/keys/time sigs/dynamics/etc don't move the tick
                // cursor and don't break a beam group in between notes.
                // But conservatively we flush on barline-like things.
                if case .barLine = el { flush() }
                // Other non-timed elements (clef change, dynamic,
                // tempo, spanner, fermata, measureRepeat, keySig,
                // timeSig) pass through.
                break
            }
        }
        flush()
        return groups
    }

    /// Extract a render-ready subtype string from the Core `Arpeggio` value.
    /// `Arpeggio.subtype` is MuseScore's mscx integer code
    /// (0=NORMAL, 1=UP, 2=DOWN, 3=UP_STRAIGHT, 4=DOWN_STRAIGHT, 5=BRACKET).
    /// `ArpeggioRenderer` consumes "up" / "down" / nil — map accordingly.
    private static func arpeggioSubtype(_ arp: Arpeggio) -> String? {
        switch arp.subtype {
        case 1, 3: return "up"
        case 2, 4: return "down"
        default: return nil
        }
    }

    private static func beamLevel(_ dur: NoteDuration) -> Int {
        switch dur {
        case .eighth: return 1
        case .sixteenth: return 2
        case .thirtySecond: return 3
        case .sixtyFourth: return 4
        case .oneTwentyEighth: return 5
        case .twoFiftySixth: return 6
        default: return 0
        }
    }

    private static func beatTicks(
        timeSignature: TimeSignature?, division: Int
    ) -> Int {
        guard let ts = timeSignature else { return division }
        // Compound meter (8-denom & 3/6/9/12 numerator): dotted quarter beat.
        if ts.denominator == 8 && ts.numerator % 3 == 0 && ts.numerator > 0 {
            return (division * 3) / 2
        }
        return (division * 4) / max(1, ts.denominator)
    }

    // MARK: - Spanner anchor collection

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
                        if case .spanner(let sp) = el {
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
                        case .chord(let c):
                            tick += c.duration.ticks(
                                division: score.division)
                        case .rest(let r):
                            tick += r.duration.ticks(
                                division: score.division)
                        default: break
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Tie pairing

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
        var open: [Int: CGPoint] = [:]
        for system in document.systems {
            for measure in system.measures {
                for el in measure.elements {
                    guard case .chord(let notes, _, _, _, _, _, _) = el
                    else { continue }
                    for n in notes {
                        let absolute = CGPoint(
                            x: system.origin.x
                                + measure.origin.x
                                + n.origin.x,
                            y: system.origin.y
                                + measure.origin.y
                                + n.origin.y
                        )
                        if let back = n.tieBack, let from = open[back] {
                            pairs.append(TiePair(
                                staff: 0,
                                fromOrigin: from,
                                toOrigin: absolute,
                                above: n.step <= 0
                            ))
                            open[back] = nil
                        }
                        if let fwd = n.tieForward {
                            open[fwd] = absolute
                        }
                    }
                }
            }
        }
        return pairs
    }

    // MARK: - Spanner attach pass

    private static func attachSpanners(
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
            for localIdx in 0..<system.measures.count {
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
                min(anchor.endMeasure,
                    (measureLocation.keys.max() ?? anchor.startMeasure)))
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
                    in: system, belowStaff: belowStaff, metrics: metrics)
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
                    metrics: metrics)
                extraPerSystem[startSys].append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(x: fromX, y: yStart),
                    toOrigin: CGPoint(x: toXStart, y: yStart),
                    continuesLeft: false,
                    continuesRight: true,
                    text: anchor.rawType
                ))
                if endSys > startSys + 1 {
                    for mid in (startSys + 1)..<endSys {
                        let midSystem = systems[mid]
                        let y = anchorY(
                            in: midSystem, belowStaff: belowStaff,
                            metrics: metrics)
                        extraPerSystem[mid].append(.spannerSegment(
                            kind: kind,
                            fromOrigin: CGPoint(
                                x: metrics.sp * 2, y: y),
                            toOrigin: CGPoint(
                                x: midSystem.size.width - metrics.sp * 2,
                                y: y),
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
                    metrics: metrics)
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
                spanners: system.spanners + extraPerSystem[idx]
            )
        }
    }

    private static func isBelowStaff(kind: Spanner.Kind) -> Bool {
        switch kind {
        case .hairpin, .pedal: return true
        default: return false
        }
    }

    private static func anchorY(
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

    private static func layoutKind(
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

    // MARK: - Tie attach pass

    private static func attachTies(
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

    private static func systemIndex(
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
