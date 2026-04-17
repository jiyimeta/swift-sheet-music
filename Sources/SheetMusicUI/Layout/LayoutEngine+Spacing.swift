#if os(macOS)
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, *)
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
    static func computeHeaderSchedule(
        measureIdx: Int,
        staves: [StaffContent],
        metrics: StaffMetrics,
        synthesizeClefForAllStaves: Bool
    ) -> HeaderSchedule {
        var clefWidth: CGFloat = 0
        var keySigWidth: CGFloat = 0
        var timeSigWidth: CGFloat = 0

        for staff in staves {
            guard measureIdx < staff.measures.count else { continue }
            let measure = staff.measures[measureIdx]
            // On the first system, every staff draws a clef (either
            // explicit or synthesized). Ensure the clef column is sized
            // even when no staff has a literal <Clef>.
            if synthesizeClefForAllStaves {
                clefWidth = max(clefWidth, metrics.sp * 3)
            }
            let leading = measure.voices.first?.elements ?? []
            for el in leading {
                var stop = false
                switch el {
                case .clef:
                    clefWidth = max(clefWidth, metrics.sp * 3)
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

    static func minimumMeasureWidth(
        measure: Measure,
        metrics: StaffMetrics
    ) -> CGFloat {
        let leftPadding = metrics.sp * 3
        // Right padding must cover the last element's body (notehead +
        // possible flag/dot/lyric) that extends past its x anchor, plus
        // room for the trailing barline.
        let rightPadding = metrics.sp * 5
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
                    let tickW = durationWidth(c.duration, metrics: metrics)
                    let lyricW = lyricsWidth(c.lyrics, metrics: metrics)
                    w += max(tickW, lyricW)
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
        // Potentially-flagged durations (8th and shorter) need extra
        // clearance so the flag glyph — which hangs ~1.1 sp past the
        // stem x — doesn't crash into the next note. Non-flagged
        // durations (quarter and longer, plus fractions that aren't
        // clean dotted bases) just need enough room for a notehead.
        let (base, _) = DurationInterpretation.split(dur)
        let floor: CGFloat
        switch base {
        case .eighth, .sixteenth, .thirtySecond, .sixtyFourth,
             .oneTwentyEighth, .twoFiftySixth:
            floor = metrics.sp * 3
        default:
            floor = metrics.sp * 2
        }
        return max(baseWidth, floor)
    }

    /// Estimated minimum horizontal space needed by a chord's lyrics so
    /// adjacent syllables don't overlap. Returns 0 when the chord has
    /// no lyrics. Uses a rough per-character width estimate (measuring
    /// via CoreText would be more precise but expensive inside a tight
    /// layout loop). The font is ~2.2 sp; average character width ≈
    /// 1.0 sp.
    static func lyricsWidth(
        _ lyrics: [String], metrics: StaffMetrics
    ) -> CGFloat {
        guard let widest = lyrics.max(by: { $0.count < $1.count }),
              !widest.isEmpty else { return 0 }
        let charWidth = metrics.sp * 1.0
        let padding = metrics.sp * 1.5
        return CGFloat(widest.count) * charWidth + padding
    }
}
#endif
