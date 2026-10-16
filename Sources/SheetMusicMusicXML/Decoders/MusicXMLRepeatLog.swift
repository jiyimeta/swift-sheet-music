import SheetMusicCore
import SheetMusicFoundation

/// A marker or jump a direction made, where it was written: its measure and its tick in that measure.
struct MusicXMLRepeatItem: Sendable, Equatable {
    enum Element: Sendable, Equatable {
        case marker(Marker)
        case jump(Jump)
    }

    var measure: Int
    var tick: Fraction
    var element: Element

    /// The item is set in MuseScore's REPEAT_RIGHT style and stands at its bar's end: a right marker
    /// (`Marker.isRightMarker`) or any jump.
    var standsAtBarEnd: Bool {
        switch element {
        case let .marker(marker): marker.isRightMarker
        case .jump: true
        }
    }
}

/// A part's markers and jumps, collected in document order as the walk meets them and placed once the part's measure
/// lengths are known (`handleRepeats`, `importmusicxmlpass2.cpp:~4652-4773`).
struct MusicXMLRepeatLog: Sendable, Equatable {
    /// A segno already made at a part tick, and its xml text (MuseScore's `SegnoStack`).
    private struct Segno: Sendable, Equatable {
        var index: Int
        var xmlText: String
    }

    private static let segnoSymbol = "<sym>segno</sym>"

    private(set) var items: [MusicXMLRepeatItem] = []
    private var segnos: [Fraction: Segno] = [:]

    /// Records what one direction made at `tick` in `measure`, which starts at `partTick` in the part. A second segno
    /// at a part tick that already has one, both holding the segno sign, is not a marker of its own: its text joins
    /// the first's, which takes an "i" per sign on its label — two segnos make one labeled `segnoii` (`P2:~4718-4730`).
    mutating func add(_ decoded: MusicXMLJumpDecoder.Decoded, measure: Int, tick: Fraction, partTick: Fraction) {
        if let words = decoded.segnoWords, let marker = decoded.markers.first {
            let at = partTick + tick
            if let previous = segnos[at] {
                if previous.xmlText.hasSubstring(Self.segnoSymbol), words.hasSubstring(Self.segnoSymbol) {
                    merge(words, into: previous, at: at)
                    return
                }
            } else {
                // A segno with no text of its own has its type's (`Marker::xmlText`).
                segnos[at] = Segno(index: items.count, xmlText: words.isEmpty ? marker.kind.defaultXMLText : words)
            }
        }
        for marker in decoded.markers {
            items.append(MusicXMLRepeatItem(measure: measure, tick: tick, element: .marker(marker)))
        }
        for jump in decoded.jumps {
            items.append(MusicXMLRepeatItem(measure: measure, tick: tick, element: .jump(jump)))
        }
    }

    private mutating func merge(_ words: String, into previous: Segno, at tick: Fraction) {
        let combined = previous.xmlText + " " + words
        segnos[tick] = Segno(index: previous.index, xmlText: combined)
        guard case var .marker(marker) = items[previous.index].element else { return }
        let carrier = MusicXMLFormattedWords.carrier(fromXMLText: combined)
        marker.text = carrier.plain
        marker.preservedTextMarkup = carrier.markup
        marker.label += String(repeating: "i", count: combined.occurrences(of: Self.segnoSymbol))
        items[previous.index].element = .marker(marker)
    }

    /// The items in the bars MuseScore puts them in: exporters sometimes write a jump or marker on the wrong side of
    /// the bar line, so a bar-end item nearer its bar's start goes to the previous bar, and a bar-start item at or past
    /// the middle of its bar to the next one (`closerToLeft`, `P2:~4749-4761`). The bars' extents are the walk's own
    /// clock — the recorded `measureLengths`, which `MusicXMLMeasureState.partTick` sums — not the octave-shift scan's
    /// `measureStart`.
    func settled(measureLengths: [Fraction]) -> [MusicXMLRepeatItem] {
        items.map { item in
            guard measureLengths.indices.contains(item.measure) else { return item }
            let closerToLeft = item.tick.precedes(measureLengths[item.measure] - item.tick)
            var moved = item
            if item.standsAtBarEnd, closerToLeft, item.measure > 0 {
                moved.measure -= 1
            } else if !item.standsAtBarEnd, !closerToLeft, item.measure + 1 < measureLengths.count {
                moved.measure += 1
            }
            return moved
        }
    }

    /// Appends the settled items, in document order, to the part's first staff — MuseScore attaches measure-level
    /// jumps and markers there, as the .mscx layout keeps them on `<Staff id="1">`'s `<Measure>`.
    func apply(measureLengths: [Fraction], to measures: inout [Measure]) {
        for item in settled(measureLengths: measureLengths) where measures.indices.contains(item.measure) {
            switch item.element {
            case let .marker(marker): measures[item.measure].markers.append(marker)
            case let .jump(jump): measures[item.measure].jumps.append(jump)
            }
        }
    }
}
