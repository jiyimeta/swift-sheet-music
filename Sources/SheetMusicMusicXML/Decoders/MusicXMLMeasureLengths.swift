import SheetMusicCore
import SheetMusicFoundation

/// The score's measure lengths, which MuseScore takes from every part at once: a measure is as long as its longest
/// part (`determineMeasureLength`, `P1:453-480`), and one whose length is not its time signature's is irregular,
/// which a saved measure says with `len` (`MeasureWrite::writeMeasure`) and the model with `Measure.actualLength`.
struct MusicXMLMeasureLengths {
    /// One part's lengths, measure by measure, and the time signature's length in force at each.
    struct PartLengths {
        private(set) var lengths: [Fraction] = []
        private(set) var nominal: [Fraction?] = []

        mutating func append(_ length: Fraction, nominal nominalLength: Fraction?) {
            lengths.append(length)
            nominal.append(nominalLength)
        }
    }

    let parts: [PartLengths]

    /// The longest part's length for measure `index`, nil past every part's end.
    func length(ofMeasure index: Int) -> Fraction? {
        parts.compactMap { $0.lengths.indices.contains(index) ? $0.lengths[index] : nil }
            .reduce(nil) { longest, length in
                guard let longest else { return length }
                return longest.precedes(length) ? length : longest
            }
    }

    /// The time signature's length for measure `index`: each part's pass 2 sets the measure's in turn
    /// (`measure->setTimesig`, `P2:2991-2993`), so the last part with a `<time>` by then decides.
    func nominalLength(ofMeasure index: Int) -> Fraction? {
        parts.reversed().lazy.compactMap { $0.nominal.indices.contains(index) ? $0.nominal[index] : nil }.first
    }

    /// `parts` with every staff's measure that is not its time signature's length given its length.
    func applied(to parts: [Part]) -> [Part] {
        parts.map { part in
            var copy = part
            copy.staves.mapValues { staff in
                var changed = staff
                for index in changed.measures.indices {
                    guard let length = length(ofMeasure: index), let nominal = nominalLength(ofMeasure: index),
                          length != nominal
                    else { continue }
                    changed.measures[index].actualLength = length
                }
                return changed
            }
            return copy
        }
    }
}
