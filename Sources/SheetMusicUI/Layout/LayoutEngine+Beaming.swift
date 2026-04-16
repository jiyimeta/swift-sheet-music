#if os(macOS)
import SheetMusicCore

@available(macOS 15.0, *)
extension LayoutEngine {
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
                break
            }
        }
        flush()
        return groups
    }

    static func beamLevel(_ dur: NoteDuration) -> Int {
        // Unwrap a dotted duration (stored as `.fraction`) to its base
        // — a dotted 8th beams like an 8th (level 1), not like a
        // non-beamable fraction.
        let (base, _) = DurationInterpretation.split(dur)
        switch base {
        case .eighth: return 1
        case .sixteenth: return 2
        case .thirtySecond: return 3
        case .sixtyFourth: return 4
        case .oneTwentyEighth: return 5
        case .twoFiftySixth: return 6
        default: return 0
        }
    }

    static func beatTicks(
        timeSignature: TimeSignature?, division: Int
    ) -> Int {
        guard let ts = timeSignature else { return division }
        // Compound meter (8-denom & 3/6/9/12 numerator): dotted quarter beat.
        if ts.denominator == 8 && ts.numerator % 3 == 0 && ts.numerator > 0 {
            return (division * 3) / 2
        }
        return (division * 4) / max(1, ts.denominator)
    }
}
#endif
