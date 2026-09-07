import SheetMusicFoundation

extension FNV1a {
    /// `visible == false` and a set `color` are the occupants; a default `ElementProperties` feeds nothing.
    mutating func combineOccupied(_ properties: ElementProperties, visibleTag: Int, colorTag: Int) {
        if !properties.visible { combine(visibleTag) }
        if let color = properties.color {
            combine(colorTag)
            combine(color.red)
            combine(color.green)
            combine(color.blue)
            combine(color.alpha)
        }
    }

    /// Chord-anchored spanner begins (`Chord.spanners` — slurs, in practice), BY OCCUPANTS: an empty array feeds
    /// nothing, so every chord in a score without slurs hashes exactly as it did before this walk existed, which
    /// is what keeps the committed replay goldens byte-identical (`ScoreFingerprintTests
    /// .defaultsHashUnchanged`). A count byte would have been the obvious spelling and would have moved them all.
    ///
    /// Closes the blind spot `ScoreFingerprint.swift` names and spec §2.5's group-1 amendment assigns to group 6:
    /// without it a `SetSlur` / `RemoveSpanner` pair is invisible to every golden.
    mutating func combineOccupied(_ spanners: [Spanner], tag: Int) {
        guard !spanners.isEmpty else { return }
        combine(tag)
        combine(spanners.count)
        for spanner in spanners {
            combine(spanner)
        }
    }

    /// Chord ornaments (`Chord.ornaments`), BY OCCUPANTS for the same reason
    /// `combineOccupied(_ spanners:tag:)` is: a chord that carries none must
    /// feed no bytes, or every committed replay golden moves.
    mutating func combineOccupied(_ ornaments: [ChordOrnament], tag: Int) {
        guard !ornaments.isEmpty else { return }
        combine(tag)
        combine(ornaments.count)
        for ornament in ornaments {
            combine(ornament)
        }
    }

    /// Note fingerings, BY OCCUPANTS — same rule, same reason, as
    /// `combineOccupied(_ ornaments:tag:)`.
    mutating func combineOccupied(_ fingerings: [Fingering], tag: Int) {
        guard !fingerings.isEmpty else { return }
        combine(tag)
        combine(fingerings.count)
        for fingering in fingerings {
            combine(fingering)
        }
    }

    /// Note-attached engraving symbols, BY OCCUPANTS: an empty array feeds no
    /// bytes, so scores without them retain their committed replay fingerprint.
    mutating func combineOccupied(_ symbols: [EngravingSymbol], tag: Int) {
        guard !symbols.isEmpty else { return }
        combine(tag)
        combine(symbols.count)
        for symbol in symbols {
            combine(symbol)
        }
    }

    /// A chord bracket, BY OCCUPANTS: an absent bracket feeds no bytes, so
    /// every score without one keeps its committed replay fingerprint.
    mutating func combineOccupied(_ bracket: ChordBracket?, tag: Int) {
        guard let bracket else { return }
        combine(tag)
        combinePresence(bracket.hookLength)
        combine(bracket.hookPosition?.rawValue)
        combineTristate(bracket.isRightSide)
        combineOccupied(bracket.elementProperties, visibleTag: 44, colorTag: 45)
    }

    /// Figured-bass items, BY OCCUPANTS: an empty item representation feeds
    /// nothing, keeping it distinct from the raw-text payload by the parent
    /// fingerprint fields without introducing an empty-list marker.
    mutating func combineOccupied(_ items: [FiguredBassItem], tag: Int) {
        guard !items.isEmpty else { return }
        combine(tag)
        combine(items.count)
        for item in items {
            combine(item)
        }
    }

    /// A time signature's symbol (`TimeSignature.symbol`), BY OCCUPANTS for the same reason
    /// `combineOccupied(_ spanners:tag:)` is: `.numeric` feeds no bytes, so every score whose signatures are
    /// drawn as numbers — which is every committed golden — hashes exactly as it did before the symbol
    /// existed.
    ///
    /// It has to be here at all because `.setTimeSignature` writes the symbol: without it, a mirror that
    /// applied the meter but not the C would agree with one that applied both.
    mutating func combineOccupied(_ symbol: TimeSignatureSymbol, tag: Int) {
        guard symbol != .numeric else { return }
        combine(tag)
        combine(symbol.rawValue)
    }
}
