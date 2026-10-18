/// A time signature read the way a rhythm splitter needs it: which positions in the bar are beats, which of those are
/// stressed, and how finely a position subdivides. Every position is a tick count from the bar's notional start.
struct RhythmMeter {
    /// Strongest first, so `<=` reads "at least this strong".
    enum BeatType: Int, Comparable {
        case downbeat, compoundStressed, simpleStressed, compoundUnstressed, simpleUnstressed, compoundSubbeat, subbeat

        static func < (lhs: BeatType, rhs: BeatType) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let numerator: Int

    /// Ticks of one denominator unit (the "dUnit"): an eighth in x/8, a quarter in x/4.
    let dUnitTicks: Int

    /// Callers check `isReadable` first; a meter that fails it would divide by zero or round the dUnit.
    init(numerator: Int, denominator: Int, division: Int) {
        precondition(
            Self.isReadable(numerator: numerator, denominator: denominator, division: division),
            "unreadable meter \(numerator)/\(denominator) at division \(division)",
        )
        self.numerator = numerator
        dUnitTicks = (4 * division) / denominator
    }

    /// The meter has beats to read: a positive numerator, and a denominator that splits a whole note into a whole
    /// number of ticks.
    static func isReadable(numerator: Int, denominator: Int, division: Int) -> Bool {
        numerator > 0 && denominator > 0 && division > 0 && (4 * division) % denominator == 0
    }

    /// Numerator above three and divisible by three: 6/8, 9/8, 12/8. 3/8 is simple.
    var isCompound: Bool {
        numerator > 3 && numerator % 3 == 0
    }

    private var dUnitsPerBeat: Int {
        isCompound ? 3 : 1
    }

    var beatTicks: Int {
        dUnitTicks * dUnitsPerBeat
    }

    var beatsPerMeasure: Int {
        numerator / dUnitsPerBeat
    }

    var isTriple: Bool {
        beatsPerMeasure % 3 == 0
    }

    /// Only meaningful when `!isTriple`.
    var isDuple: Bool {
        !isTriple && beatsPerMeasure % 2 == 0
    }

    private func subbeatTicks(level: Int) -> Int {
        dUnitTicks >> level
    }

    func beatType(at rtick: Int) -> BeatType {
        if rtick == 0 { return .downbeat }
        if rtick % dUnitTicks != 0 { return .subbeat }
        if isCompound, rtick % beatTicks != 0 { return .compoundSubbeat }
        let beatNumber = rtick / beatTicks
        // The bar end is a stressed beat in duple and triple meters, but not in 5/8 or 7/8 (stress every
        // (n + 1) / 2 beats), which is what lets a syncopation tie into the barline survive in the former.
        let stress = isTriple ? 3 : (isDuple ? 2 : (numerator + 1) / 2)
        if stress != 0, beatNumber % stress == 0 {
            return isCompound ? .compoundStressed : .simpleStressed
        }
        return isCompound ? .compoundUnstressed : .simpleUnstressed
    }

    /// How many halvings of the dUnit it takes to reach `rtick`'s position: 0 on a dUnit boundary, 1 on a half-dUnit
    /// boundary, and so on. Negative (the negated level reached) once the dUnit stops halving evenly: the position is
    /// off any power-of-two subdivision and the caller falls back to greedy spelling.
    func subbeatLevel(at rtick: Int) -> Int {
        var level = 0
        var size = dUnitTicks
        var remainder = rtick % size
        while remainder != 0 {
            level += 1
            if size % 2 != 0 { return -level }
            size /= 2
            remainder %= size
        }
        return level
    }

    /// The coarsest subdivision level whose boundary lies inside `[from, to)`, and the LAST such boundary. A negative
    /// level (with no split) means the range cannot be judged on power-of-two subdivisions.
    func strongestSubbeatLevel(from rtick1: Int, to rtick2: Int) -> (level: Int, split: Int?) {
        var level = 0
        var size = dUnitTicks
        while true {
            let first = rtick1 / size
            let last = (rtick2 - 1) / size
            if last > first { return (level, last * size) }
            level += 1
            if size % 2 != 0 { return (-level, nil) }
            size /= 2
        }
    }

    /// The strongest dUnit boundary strictly inside `(from, to)`, how many boundaries there are, and where the
    /// strongest one is. With `savingLast` a later boundary of equal strength wins (the split falls on the LAST of
    /// them); without it the first wins.
    func strongestBeat(
        from rtick1: Int, to rtick2: Int, savingLast: Bool,
    ) -> (type: BeatType, dUnitsCrossed: Int, split: Int?) {
        var strongest = BeatType.subbeat
        var crossed = 0
        var split: Int?
        var rtick = rtick1 + (dUnitTicks - rtick1 % dUnitTicks)
        while rtick < rtick2 {
            crossed += 1
            let type = beatType(at: rtick)
            if type.rawValue < strongest.rawValue + (savingLast ? 1 : 0) {
                strongest = type
                split = rtick
            }
            rtick += dUnitTicks
        }
        return (strongest, crossed, split)
    }

    func ticksPastBeat(_ rtick: Int) -> Int {
        rtick % beatTicks
    }

    func ticksToNextBeat(_ rtick: Int) -> Int {
        beatTicks - ticksPastBeat(rtick)
    }

    func ticksPastSubbeat(_ rtick: Int, level: Int) -> Int {
        rtick % subbeatTicks(level: level)
    }

    func ticksToNextSubbeat(_ rtick: Int, level: Int) -> Int {
        subbeatTicks(level: level) - ticksPastSubbeat(rtick, level: level)
    }
}
