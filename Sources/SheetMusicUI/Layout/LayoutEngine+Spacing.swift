import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// Per-measure shared header layout. All staves in a multi-staff
    /// system use the same x-positions for clef / key sig / time sig
    /// so that a drum or tab staff (which has no key signature) still
    /// places its time signature at the same x as a pitched staff that
    /// does. Without this, drum/tab time signatures would slide left
    /// and break vertical alignment across the system.
    struct HeaderSchedule: Sendable, Equatable {
        let clefX: CGFloat
        let keySigX: CGFloat
        let timeSigX: CGFloat
        let contentStartX: CGFloat
    }

    /// Compute the shared header schedule for `measureIdx` across all
    /// staves. Each column's width is the max width consumed by any
    /// staff that carries that element, so staves lacking an element
    /// simply skip its slot (empty visual space).
    ///
    /// `synthesizeKeySigForAllStaves` + `activeKeys` reserve header
    /// width for a key signature even when the measure has no literal
    /// `<KeySig>` — used at the start of continuation systems to
    /// redraw the currently active key.
    static func computeHeaderSchedule(
        measureIdx: Int,
        staves: [StaffContent],
        metrics: StaffMetrics,
        synthesizeClefForAllStaves: Bool,
        synthesizeKeySigForAllStaves: Bool = false,
        activeKeys: [Int]? = nil
    ) -> HeaderSchedule {
        var clefWidth: CGFloat = 0
        var keySigWidth: CGFloat = 0
        var timeSigWidth: CGFloat = 0

        for (idx, staff) in staves.enumerated() {
            guard measureIdx < staff.measures.count else { continue }
            let measure = staff.measures[measureIdx]
            // On the first system, every staff draws a clef (either
            // explicit or synthesized). Ensure the clef column is sized
            // even when no staff has a literal <Clef>.
            if synthesizeClefForAllStaves {
                clefWidth = max(clefWidth, metrics.sp * 2)
            }
            // When a continuation system synthesises the active key
            // signature, reserve width based on that staff's carried
            // key — even if the measure itself has no literal
            // <KeySig> element.
            if synthesizeKeySigForAllStaves,
               let keys = activeKeys,
               idx < keys.count,
               keys[idx] != 0 {
                keySigWidth = max(
                    keySigWidth,
                    metrics.sp * (CGFloat(abs(keys[idx])) + 1.5))
            }
            let leading = measure.voices.first?.elements ?? []
            for el in leading {
                var stop = false
                switch el {
                case .clef:
                    clefWidth = max(clefWidth, metrics.sp * 2)
                case .keySignature(let k):
                    keySigWidth = max(
                        keySigWidth,
                        metrics.sp * (CGFloat(abs(k.concertKey)) + 1.5))
                case .timeSignature:
                    timeSigWidth = max(timeSigWidth, metrics.sp * 3)
                case .chord, .rest:
                    stop = true
                default:
                    break
                }
                if stop { break }
            }
        }

        let clefX = metrics.sp * 2
        let keySigX = clefX + clefWidth
        let timeSigX = keySigX + keySigWidth
        let contentStartX = timeSigX + timeSigWidth
            + (timeSigWidth > 0 ? metrics.sp * 0.5 : 0)
        return HeaderSchedule(
            clefX: clefX,
            keySigX: keySigX,
            timeSigX: timeSigX,
            contentStartX: contentStartX
        )
    }

    /// Width a single-system layout of `score` would occupy at its
    /// uncompressed minimum. Sum of per-measure minimum widths + the
    /// first-system part-label reservation.
    ///
    /// Used by `ScoreView` as the `minWidth` floor so the view doesn't
    /// collapse when a parent proposes nil/tiny width (e.g. inside
    /// `ScrollView([.vertical, .horizontal])`).
    public static func naturalContentWidth(
        score: Score, options: ScoreViewOptions
    ) -> CGFloat {
        let metrics = StaffMetrics(staffSize: options.staffSize)
        let partLabelWidth: CGFloat = 80
        guard let firstStaff = score.staves.first else {
            return partLabelWidth + metrics.sp * 8
        }
        let measureCount = firstStaff.measures.count
        guard measureCount > 0 else {
            return partLabelWidth + metrics.sp * 8
        }
        var total: CGFloat = partLabelWidth
        for i in 0..<measureCount {
            let w = score.staves.map { staff -> CGFloat in
                guard i < staff.measures.count else { return 0 }
                return minimumMeasureWidth(
                    measure: staff.measures[i],
                    metrics: metrics)
            }.max() ?? 0
            total += w
        }
        return total
    }

    /// Shared x-coordinate for every unique tick in a measure, computed
    /// across all voices of all staves.  Mirrors MuseScore's segment
    /// concept: notes at the same tick share one horizontal position
    /// no matter which staff or voice they live in.
    ///
    /// Algorithm (pro-rated gap aggregation):
    /// 1. Collect every unique tick at which ANY voice has a timed
    ///    element starting, plus the measure end (the "fence post"
    ///    after the last tick).
    /// 2. For each pair of consecutive ticks `(t_i, t_{i+1})`, compute
    ///    the minimum horizontal space needed — the MAX across voices
    ///    of the element active at `t_i` scaled to the portion of its
    ///    duration that falls inside `(t_i, t_{i+1})`.  Pro-rating is
    ///    what keeps a long voice-1 element (e.g. a whole note) from
    ///    stealing space from voice 0's uniform quarters, while still
    ///    reserving enough room for its own tick boundaries.
    /// 3. Prefix-sum the gap weights.  Because gap weights are
    ///    non-negative, the resulting x sequence is MONOTONIC — no
    ///    tick ever lands left of an earlier one, even when voices
    ///    have different element counts.
    ///
    /// Returns an empty map when the measure has no timed content.
    static func tickColumns(
        staves: [StaffContent],
        measureIdx: Int,
        metrics: StaffMetrics,
        headerSchedule: HeaderSchedule,
        width: CGFloat,
        division: Int
    ) -> [Int: CGFloat] {
        struct TimedElement {
            let startTick: Int
            let endTick: Int
            let weight: CGFloat
        }
        var voiceElements: [[TimedElement]] = []
        var allTicks: Set<Int> = []
        var measureEnd: Int = 0

        for staff in staves where measureIdx < staff.measures.count {
            for voice in staff.measures[measureIdx].voices {
                var elements: [TimedElement] = []
                var tick = 0
                for el in voice.elements {
                    switch el {
                    case .chord(let c):
                        let w = max(
                            durationWidth(c.duration, metrics: metrics),
                            lyricsWidth(c.lyrics, metrics: metrics))
                        let end = tick + c.duration.ticks(division: division)
                        elements.append(TimedElement(
                            startTick: tick, endTick: end, weight: w))
                        allTicks.insert(tick)
                        tick = end
                    case .rest(let r):
                        let w = durationWidth(r.duration, metrics: metrics)
                        let end = tick + r.duration.ticks(division: division)
                        elements.append(TimedElement(
                            startTick: tick, endTick: end, weight: w))
                        allTicks.insert(tick)
                        tick = end
                    default:
                        break
                    }
                }
                if !elements.isEmpty {
                    voiceElements.append(elements)
                    measureEnd = max(measureEnd, tick)
                }
            }
        }

        guard !allTicks.isEmpty else { return [:] }
        let sortedTicks = allTicks.sorted()

        // Gap weights: max pro-rated contribution across voices per
        // inter-tick segment.  We also append one trailing gap from
        // the last tick to `measureEnd` so the final element still
        // reserves horizontal space.
        var gapWeights: [CGFloat] = []
        gapWeights.reserveCapacity(sortedTicks.count)
        for i in 0..<sortedTicks.count {
            let tStart = sortedTicks[i]
            let tEnd = i + 1 < sortedTicks.count
                ? sortedTicks[i + 1]
                : measureEnd
            let gapTicks = tEnd - tStart
            guard gapTicks > 0 else {
                gapWeights.append(0)
                continue
            }
            var maxGap: CGFloat = 0
            for elements in voiceElements {
                for el in elements where el.startTick <= tStart
                    && el.endTick > tStart {
                    let duration = el.endTick - el.startTick
                    guard duration > 0 else { break }
                    let share = el.weight
                        * CGFloat(gapTicks) / CGFloat(duration)
                    maxGap = max(maxGap, share)
                    break
                }
            }
            gapWeights.append(maxGap)
        }

        let totalWeight = gapWeights.reduce(0, +)
        // Trailing slack between the last note's tick position and
        // the right barline. Matches `minimumMeasureWidth`'s
        // `rightPadding`; if these drift apart, chord-to-x mapping
        // and minimum-width allocation disagree and the system
        // packer hands `chordSpacingTickToX` a `width` that under-
        // allocates the chord area.
        let trailingGap = metrics.sp * 1
        let contentWidth = max(
            metrics.sp * 4,
            width - headerSchedule.contentStartX - trailingGap)
        let baseX = headerSchedule.contentStartX + metrics.sp

        var tickToX: [Int: CGFloat] = [:]
        var cumulative: CGFloat = 0
        for (i, t) in sortedTicks.enumerated() {
            let fraction = totalWeight > 0 ? cumulative / totalWeight : 0
            tickToX[t] = baseX + fraction * contentWidth
            cumulative += gapWeights[i]
        }
        return tickToX
    }

    /// Extra width the FIRST measure of a system needs beyond its
    /// natural `minimumMeasureWidth` to fit the clef + key signature
    /// that engraving redraws at every system head.
    ///
    /// `minimumMeasureWidth` only counts elements physically present
    /// inside the measure's `<voice>`. When wrapping promotes an
    /// interior measure to a system head, `computeHeaderSchedule`
    /// synthesises a clef + key signature at the line start — eating
    /// into the chord content area without anyone having reserved the
    /// space. The result is squeezed lyrics that overlap each other,
    /// despite the same measure spacing fine in horizontal mode.
    /// We compute the synth overhead here and add it to the first
    /// measure's width during system packing.
    static func synthHeaderOverhead(
        staves: [StaffContent],
        measureIdx: Int,
        activeKeys: [Int],
        metrics: StaffMetrics
    ) -> CGFloat {
        var clefBoost: CGFloat = 0
        var keyBoost: CGFloat = 0
        for (staffIdx, staff) in staves.enumerated() {
            guard measureIdx < staff.measures.count else { continue }
            let measure = staff.measures[measureIdx]
            var hasExplicitClef = false
            var explicitKeyWidth: CGFloat = 0
            scan: for el in measure.voices.first?.elements ?? [] {
                switch el {
                case .clef:
                    hasExplicitClef = true
                case .keySignature(let k):
                    explicitKeyWidth = max(
                        explicitKeyWidth,
                        metrics.sp * (CGFloat(abs(k.concertKey)) + 1))
                case .chord, .rest:
                    break scan
                default:
                    continue
                }
            }
            if !hasExplicitClef {
                clefBoost = max(clefBoost, metrics.sp * 2)
            }
            let activeKey = staffIdx < activeKeys.count
                ? activeKeys[staffIdx] : 0
            if activeKey != 0 {
                let synthKeyW = metrics.sp
                    * (CGFloat(abs(activeKey)) + 1.5)
                keyBoost = max(
                    keyBoost,
                    max(0, synthKeyW - explicitKeyWidth))
            }
        }
        return clefBoost + keyBoost
    }

    static func minimumMeasureWidth(
        measure: Measure,
        metrics: StaffMetrics
    ) -> CGFloat {
        // MuseScore's `Sid::measureSpacing` defaults yield roughly
        // 1.5 sp of leading padding and ~1 sp of trailing slack;
        // anything more would force ~3 measures / system on
        // typical part scores instead of MuseScore's 4. Previous
        // 3 sp + 3 sp sum was tuned for the stand-alone single-
        // staff demo and over-padded multi-measure rows.
        let leftPadding = metrics.sp * 1.5
        let rightPadding = metrics.sp * 1
        var maxVoiceWidth: CGFloat = 0
        for voice in measure.voices {
            var w: CGFloat = 0
            for el in voice.elements {
                switch el {
                case .clef:
                    w += metrics.sp * 2
                case .keySignature(let k):
                    w += metrics.sp * (CGFloat(abs(k.concertKey)) + 1)
                case .timeSignature:
                    w += metrics.sp * 3
                case .barLine:
                    w += metrics.sp
                case .chord(let c):
                    let tickW = durationWidth(c.duration, metrics: metrics)
                    let lyricW = lyricsWidth(c.lyrics, metrics: metrics)
                    w += max(tickW, lyricW)
                case .rest(let r):
                    w += durationWidth(r.duration, metrics: metrics)
                case .dynamic, .tempo, .fermata,
                     .measureRepeat, .spanner, .staffText:
                    break
                }
            }
            maxVoiceWidth = max(maxVoiceWidth, w)
        }
        return leftPadding + maxVoiceWidth + rightPadding
    }

    static func durationWidth(
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
        let baseWidth = metrics.spacePerQuarter * CGFloat(quarters)
        // Per-note clearance floor. MuseScore's
        // `Sid::shortestNoteDistance` defaults to 1.5 sp for short
        // notes (8th and shorter — flagged or beamed); anything else
        // needs only enough room for the notehead. Beam vs. flag is
        // handled at render time, so this floor is a single value
        // that protects against zero-width collapse.
        let (base, _) = DurationInterpretation.split(dur)
        let floor: CGFloat
        switch base {
        case .eighth, .sixteenth, .thirtySecond, .sixtyFourth,
             .oneTwentyEighth, .twoFiftySixth:
            floor = metrics.sp * 1.5
        default:
            floor = metrics.sp * 1.5
        }
        return max(baseWidth, floor)
    }

    /// Minimum horizontal space needed by a chord's lyrics so adjacent
    /// syllables don't overlap. Returns 0 when the chord has no lyrics.
    ///
    /// Horizontal contribution one chord's lyric makes to the
    /// chord's minimum width, factoring in that lyrics are
    /// **centre-anchored** under the notehead and so half of every
    /// syllable extends LEFT of the chord's x and half extends RIGHT.
    ///
    /// MuseScore's spacing rule: adjacent chords with lyrics must be
    /// at least `lyricRightHalf[i] + lyricLeftHalf[i+1] +
    /// Sid::lyricsMinDistance` (≈ 0.25 sp) apart. When all chords
    /// have the same syllable width that simplifies to one full
    /// syllable per chord PLUS one extra at the row's start, which
    /// is what we approximate here: `widest / 2 + lyricsMinDistance`.
    ///
    /// The previous formula (`widest + metrics.sp`) treated each
    /// chord as if it owned a full syllable's worth of horizontal
    /// space INDEPENDENTLY of neighbours — it inflated 16-chord
    /// rapid-lyric measures (e.g. "tu lu tu lu …") to roughly twice
    /// MuseScore's output, dropping our systems-per-page from 4 to
    /// 2-3 measures.
    static func lyricsWidth(
        _ lyrics: [Lyric], metrics: StaffMetrics
    ) -> CGFloat {
        var widest: CGFloat = 0
        for lyric in lyrics where !lyric.text.isEmpty {
            widest = max(
                widest,
                lyricsTextWidth(lyric.text, sp: metrics.sp))
        }
        guard widest > 0 else { return 0 }
        // Half-syllable extent + MuseScore's `lyricsMinDistance`
        // default of 0.25 sp.
        return widest / 2 + metrics.sp * 0.25
    }
}
