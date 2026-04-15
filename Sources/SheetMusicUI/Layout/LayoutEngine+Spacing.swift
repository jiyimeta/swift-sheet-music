#if os(macOS)
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, *)
extension LayoutEngine {
    static func minimumMeasureWidth(
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
        let base = metrics.spacePerQuarter * CGFloat(quarters)
        return max(base, metrics.sp * 2)
    }
}
#endif
