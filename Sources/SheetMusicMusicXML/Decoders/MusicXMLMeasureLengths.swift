import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// The score's measure lengths, which MuseScore takes from every part at once: a measure is as long as its longest
/// part (`determineMeasureLength`, `P1:453-480`), and one whose length is not its time signature's is irregular,
/// which a saved measure says with `len` (`MeasureWrite::writeMeasure`) and the model with `Measure.actualLength`.
/// A measure any part calls `implicit` is left out of the bar numbers (`measure->setIrregular`, `P2:2733-2735`).
struct MusicXMLMeasureLengths {
    /// One part's lengths, measure by measure, the time signature's length in force at each, and whether the part
    /// calls each one `implicit`.
    struct PartLengths {
        private(set) var lengths: [Fraction] = []
        private(set) var nominal: [Fraction?] = []
        private(set) var implicit: [Bool] = []

        mutating func append(_ length: Fraction, nominal nominalLength: Fraction?, of measure: XMLTreeNode) {
            lengths.append(length)
            nominal.append(nominalLength)
            implicit.append(measure.attributes["implicit"] == "yes")
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

    /// Whether some part calls measure `index` implicit — each part's pass 2 marks the one measure the parts share,
    /// and none clears it.
    func isImplicit(measure index: Int) -> Bool {
        parts.contains { $0.implicit.indices.contains(index) && $0.implicit[index] }
    }

    /// `parts` with every staff's measure that is not its time signature's length given its length, and every
    /// implicit one made irregular.
    func applied(to parts: [Part]) -> [Part] {
        parts.map { part in
            var copy = part
            copy.staves.mapValues { staff in
                var changed = staff
                for index in changed.measures.indices {
                    if isImplicit(measure: index) { changed.measures[index].irregular = true }
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
