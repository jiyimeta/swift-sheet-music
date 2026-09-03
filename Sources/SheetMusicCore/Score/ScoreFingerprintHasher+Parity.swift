import SheetMusicFoundation

/// The fields the edit-command parity project (spec 2026-09-02 §2.5) brought under the fingerprint.
///
/// Two rules, both chosen so that a score in which none of these fields is set produces the exact byte stream it
/// did before this file existed — which is what keeps every committed replay golden byte-identical:
///
/// - **Measure flags and element properties are fed BY OCCUPANTS.** A field contributes bytes only when it holds a
///   non-default value, and always as a unique non-zero tag (21 and up, so no tag can be mistaken for a
///   `VoiceElement` case tag 0…11 or for a presence byte) followed by its value. The tag is what keeps
///   `endRepeatCount = 2` and `measureRepeatCount = 2` apart; the fixed-arity prefix of each measure block is what
///   keeps "flag on measure 3" and "flag on measure 4" apart.
/// - **The marker `VoiceElement` cases are fed their content UNCONDITIONALLY.** A clef has no default type to be
///   absent from, so `combine(_ element:)` now feeds the identity of a clef, barline, dynamic, fermata, breath,
///   harmony, spanner and measure repeat rather than a bare case tag. Still byte-free for the existing chain,
///   whose fixture holds none of those elements.
extension FNV1a {
    mutating func combineFlags(_ measure: Measure) {
        if measure.lineBreak { combine(21) }
        if measure.pageBreak { combine(22) }
        if measure.sectionBreak { combine(23) }
        if measure.startRepeat { combine(24) }
        if let count = measure.endRepeatCount {
            combine(25)
            combine(count)
        }
        if let count = measure.measureRepeatCount {
            combine(26)
            combine(count)
        }
        if !measure.markers.isEmpty {
            combine(27)
            combine(measure.markers.count)
            for marker in measure.markers {
                combine(marker.kind.rawValue)
                combine(marker.label)
                combine(marker.text)
            }
        }
        if !measure.jumps.isEmpty {
            combine(28)
            combine(measure.jumps.count)
            for jump in measure.jumps {
                combine(jump.jumpTo)
                combine(jump.playUntil)
                combine(jump.continueAt)
                combine(jump.playRepeats)
                combine(jump.text)
            }
        }
    }

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

    mutating func combine(_ clef: Clef) {
        combine(clef.concertClefType)
        combine(clef.transposingClefType)
        combine(clef.visible)
    }

    mutating func combine(_ barLine: BarLine) {
        combine(barLine.subtype)
        combine(barLine.visible)
    }

    mutating func combine(_ dynamic: Dynamic) {
        combine(dynamic.subtype)
        combine(dynamic.velocity)
        combine(dynamic.visible)
    }

    mutating func combine(_ fermata: Fermata) {
        combine(fermata.subtype)
        combine(fermata.timeStretch)
        combine(fermata.visible)
    }

    mutating func combine(_ breath: Breath) {
        switch breath.kind {
        case let .breathMark(style):
            combine(0)
            combine(style.rawValue)
        case let .caesura(style):
            combine(1)
            combine(style.rawValue)
        }
        combine(breath.pause)
        combine(breath.visible)
    }

    mutating func combine(_ harmony: Harmony) {
        combine(harmony.name)
        combine(harmony.harmonyType.rawValue)
        combinePresence(harmony.rootTpc)
        combinePresence(harmony.bassTpc)
        combine(harmony.visible)
    }

    mutating func combine(_ repeat: MeasureRepeat) {
        combine(`repeat`.numMeasures)
        combine(`repeat`.duration)
    }

    mutating func combine(_ spanner: Spanner) {
        combine(spanner.kind.rawValue)
        combine(spanner.rawType)
        combine(spanner.nextMeasuresOffset)
        combine(spanner.nextFractionsOffset)
        combine(spanner.voltaEndings.count)
        for ending in spanner.voltaEndings {
            combine(ending)
        }
        combine(spanner.beginText)
        combine(spanner.placement?.rawValue)
        combinePresence(spanner.hairpin?.subtype.rawValue)
        combinePresence(spanner.hairpin?.veloChange)
        combine(spanner.hairpin?.veloChangeMethod.rawValue)
        combine(spanner.ottava?.subtype.rawValue)
        combinePresence(spanner.ottava?.numbersOnly.map { $0 ? 1 : 0 })
        combine(spanner.vibrato?.type.rawValue)
        combine(spanner.trill?.type.rawValue)
        combine(spanner.visible)
    }

    /// Explicit 0/1 presence byte for an unbounded `Int?` — the `combine(_ fraction:)` / `combine(_ address:)`
    /// rule, restated for the TPCs and velocities above, whose `-1` is a real value.
    private mutating func combinePresence(_ value: Int?) {
        guard let value else {
            combine(0)
            return
        }
        combine(1)
        combine(value)
    }
}
