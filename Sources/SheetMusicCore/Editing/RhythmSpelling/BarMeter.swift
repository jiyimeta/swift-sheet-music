/// One bar as a meter-aware speller reads it: the meter in force, the bar's actual length, and whether it is a pickup.
///
/// Every edit that has to invent durations for a span it creates — the rests a shortened note leaves, the tied pieces
/// of a note crossing a barline, the rests a range delete leaves, a column of a new barring — spells that span through
/// `durations(forTicks:at:isRest:)`, so it writes what `FormatRhythms` would write for it under
/// `RhythmSpellingPolicy.default`. `FormatRhythms` reads its pickups from the same rule, so the two cannot disagree on
/// which bar is right-aligned.
struct BarMeter: Equatable {
    let numerator: Int
    let denominator: Int
    /// The bar's actual length in ticks.
    let barTicks: Int
    /// A pickup is right-aligned against its nominal bar and never answers `.measure`.
    let isPickup: Bool
    let division: Int

    init(numerator: Int, denominator: Int, barTicks: Int, isPickup: Bool, division: Int) {
        self.numerator = numerator
        self.denominator = denominator
        self.barTicks = barTicks
        self.isPickup = isPickup
        self.division = division
    }

    /// Bar `measureIndex` of `staff`, `barTicks` long (the caller's effective measure duration). The meter is the last
    /// signature at or before the bar, 4/4 before the first.
    init(staff: Staff, measureIndex: Int, barTicks: Int, division: Int) {
        let meter = staff.prevailingTimeSignature(upTo: measureIndex) ?? TimeSignature(numerator: 4, denominator: 4)
        self.init(
            numerator: meter.numerator, denominator: meter.denominator, barTicks: barTicks,
            isPickup: Self.isPickupBar(
                staff: staff, measureIndex: measureIndex, meter: meter, barTicks: barTicks, division: division,
            ),
            division: division,
        )
    }

    /// MuseScore's narrow `isAnacrusis`: a bar shorter than its meter that is the staff's first bar, is flagged
    /// irregular (left out of bar numbering), or follows a section break. Every other short bar — a 3-beat final bar in
    /// 4/4 — is left-aligned like a full one.
    static func isPickupBar(
        staff: Staff, measureIndex: Int, meter: TimeSignature, barTicks: Int, division: Int,
    ) -> Bool {
        guard staff.measures.indices.contains(measureIndex),
              RhythmMeter.isReadable(numerator: meter.numerator, denominator: meter.denominator, division: division)
        else { return false }
        let nominal = Fraction(numerator: meter.numerator, denominator: meter.denominator).ticks(division: division)
        guard barTicks < nominal else { return false }
        return measureIndex == 0 || staff.measures[measureIndex].irregular
            || staff.measures[measureIndex - 1].sectionBreak
    }

    /// Ticks a right-aligned pickup's positions are shifted by: nominal length − actual length.
    var pickupOffset: Int {
        guard isPickup,
              RhythmMeter.isReadable(numerator: numerator, denominator: denominator, division: division)
        else { return 0 }
        return max(0, numerator * 4 * division / denominator - barTicks)
    }

    /// `ticks` starting `rtick` ticks into the bar (counted from its first element, as every editing path counts),
    /// spelled as `RhythmSpelling` spells a freshly created span under `.default`. Falls back to
    /// `DurationChangeAlgorithm.alignedDurations` when the meter cannot be read or the values cannot cover the span to
    /// the tick, so spelling never makes an edit fail.
    func durations(forTicks ticks: Int, at rtick: Int, isRest: Bool) -> [NoteDuration] {
        let spelled = RhythmSpelling.durations(
            forTicks: ticks, startingAt: rtick + pickupOffset, isRest: isRest,
            meterNumerator: numerator, meterDenominator: denominator, barTicks: barTicks, isPickup: isPickup,
            policy: .default, division: division,
        )
        guard spelled.isEmpty else { return spelled }
        return DurationChangeAlgorithm.alignedDurations(forTicks: ticks, rtickStart: rtick, division: division)
    }

    /// `durations(forTicks:at:isRest:)` for a rest span, as rests.
    func rests(forTicks ticks: Int, at rtick: Int) -> [VoiceElement] {
        durations(forTicks: ticks, at: rtick, isRest: true).map { .rest(duration: $0) }
    }
}

extension BarMeter {
    /// Bar `measureIndex` of the staff at `staff` in `score`, at its effective length. A staff the score does not have
    /// reads as a full 4/4 bar of that length, which spells as `alignedDurations` did.
    init(score: Score, staff: StaffAddress, measureIndex: Int) {
        let barTicks = score.effectiveMeasureDuration(at: staff, measureIndex: measureIndex)
            .ticks(division: score.division)
        if let found = score[staff] {
            self.init(staff: found, measureIndex: measureIndex, barTicks: barTicks, division: score.division)
        } else {
            self.init(numerator: 4, denominator: 4, barTicks: barTicks, isPickup: false, division: score.division)
        }
    }
}
