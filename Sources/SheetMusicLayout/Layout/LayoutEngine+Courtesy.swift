#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

// MARK: - End-of-system courtesy signatures

extension LayoutEngine {
    /// One staff's courtesy key signature — the key the measure that
    /// OPENS the next system changes to, announced at the trailing edge
    /// of the current system.
    ///
    /// `priorKey` is the key in force where the announcement is drawn,
    /// kept so the cancellation naturals can be resolved against the
    /// clef the announcing staff actually carries there. `newKey` is the
    /// concert key the change lands on, in the same signed form
    /// `KeySignature.concertKey` uses.
    struct CourtesyKeySignature: Equatable, Sendable {
        let staffIndex: Int
        let newKey: Int
        let priorKey: Int
    }

    /// The courtesy time signature. One per system — a time signature
    /// change is a score-wide event, so every staff announces the same
    /// numerals in the same column.
    struct CourtesyTimeSignature: Equatable, Sendable {
        let numerator: Int
        let denominator: Int
        /// Announced in the same shape the change itself is drawn in: a
        /// system ending before a cut-time bar announces the ¢, not "2/2".
        let symbol: TimeSignatureSymbol
    }

    /// Everything the trailing edge of one system announces: what to
    /// draw, where to draw it, and how much room the whole band takes.
    ///
    /// The offsets and the width are STORED rather than recomputed
    /// because two passes consume them and they must agree exactly:
    /// `packSystems` reserves `width` when it decides where the system
    /// ends, `buildSystem` subtracts the same `width` to recover the
    /// measure's content width, and the glyphs go down at the same
    /// entry's offsets. One table entry, one arithmetic.
    struct TrailingCourtesy: Equatable, Sendable {
        /// Only the staves whose key actually changes, so a change on
        /// one staff of a multi-staff score doesn't announce on the
        /// others.
        let keys: [CourtesyKeySignature]
        let time: CourtesyTimeSignature?
        /// Anchor of the FIRST accidental, relative to the announcing
        /// measure's content width. Half a glyph inside the key column's
        /// left edge, because the renderer centers each glyph on its
        /// stride.
        let keyOriginDx: CGFloat
        /// Row origin of the time signature, relative to the same
        /// content width, and half a digit inside its own column for the
        /// same reason.
        let timeOriginDx: CGFloat
        /// Total trailing reservation: leading gap, the ink of every
        /// column present, the gap between them, and the trailing pad.
        let width: CGFloat
    }

    /// Clearance around the announced columns: after the end barline,
    /// between the key and time columns, and after the last column so
    /// the glyphs don't sit flush against the system's right edge. The
    /// last of the three mirrors the `sp * 0.5` the header schedule adds
    /// after its own time-signature column.
    private static func courtesyGap(sp: CGFloat) -> CGFloat {
        sp * 0.5
    }

    /// The trailing reservation `measureIdx` carries — the announcement's
    /// width on the measure that announces, zero everywhere else. The
    /// mirror of what `packSystems` added to that measure's width, so
    /// subtracting it recovers the content width placement lays out in.
    static func courtesyReserve(
        _ courtesy: TrailingCourtesy?,
        at measureIdx: Int,
        announcingAt announcingMeasureIdx: Int?,
    ) -> CGFloat {
        guard let courtesy, measureIdx == announcingMeasureIdx else {
            return 0
        }
        return courtesy.width
    }

    /// The announcement each system boundary would carry, indexed by the
    /// measure a system would END at — so `table[i]` describes what the
    /// last measure of a system ending at `i` announces, and is driven by
    /// measure `i + 1`'s opening signatures. `nil` where nothing is
    /// announced (including the score's last measure, which has no
    /// successor).
    ///
    /// One forward walk carries the key in force per staff and the
    /// prevailing time signature, the way `cancellationNaturalWidths`
    /// carries keys: a signature only announces when it is an actual
    /// CHANGE, which the measure alone cannot tell. Computing the whole
    /// table once is also what keeps the packing pass's reservation and
    /// the build pass's emission derived from one source.
    ///
    /// Only the first voice's leading run is inspected — a signature is
    /// a measure-head element, and a change buried after a chord is a
    /// mid-measure change, which renders inline and is never announced.
    static func trailingCourtesies(
        staves: [Staff], metrics: StaffMetrics,
    ) -> [TrailingCourtesy?] {
        let measureCount = staves.map(\.measures.count).max() ?? 0
        var table = [TrailingCourtesy?](repeating: nil, count: measureCount)
        guard measureCount > 1 else { return table }
        var keys = [Int](repeating: 0, count: staves.count)
        var time: CourtesyTimeSignature?
        for measureIdx in 0 ..< measureCount {
            if measureIdx > 0 {
                table[measureIdx - 1] = courtesy(
                    announcing: measureIdx,
                    staves: staves,
                    priorKeys: keys,
                    priorTime: time,
                    metrics: metrics,
                )
            }
            for (staffIdx, staff) in staves.enumerated()
                where measureIdx < staff.measures.count
            {
                for element in staff.measures[measureIdx].voices.first?
                    .elements ?? []
                {
                    switch element {
                    case let .keySignature(key):
                        keys[staffIdx] = key.concertKey
                    case let .timeSignature(sig):
                        time = CourtesyTimeSignature(
                            numerator: sig.numerator,
                            denominator: sig.denominator,
                            symbol: sig.symbol,
                        )
                    default:
                        continue
                    }
                }
            }
        }
        return table
    }

    /// The announcement for a system that ends immediately before
    /// `measureIdx`, given the signatures in force there.
    private static func courtesy(
        announcing measureIdx: Int,
        staves: [Staff],
        priorKeys: [Int],
        priorTime: CourtesyTimeSignature?,
        metrics: StaffMetrics,
    ) -> TrailingCourtesy? {
        var courtesyKeys: [CourtesyKeySignature] = []
        var courtesyTime: CourtesyTimeSignature?
        for (staffIdx, staff) in staves.enumerated() {
            guard measureIdx < staff.measures.count else { continue }
            let priorKey = staffIdx < priorKeys.count ? priorKeys[staffIdx] : 0
            scan: for element in staff.measures[measureIdx].voices.first?
                .elements ?? []
            {
                switch element {
                case let .keySignature(key):
                    // A hidden signature draws nothing to announce, and a
                    // restatement of the key already in force is not a
                    // change — MuseScore announces neither.
                    guard key.visible, key.showCourtesy,
                          key.concertKey != priorKey else { break }
                    courtesyKeys.append(CourtesyKeySignature(
                        staffIndex: staffIdx,
                        newKey: key.concertKey,
                        priorKey: priorKey,
                    ))
                case let .timeSignature(sig):
                    guard sig.visible, sig.showCourtesy else { break }
                    let candidate = CourtesyTimeSignature(
                        numerator: sig.numerator,
                        denominator: sig.denominator,
                        symbol: sig.symbol,
                    )
                    guard candidate != priorTime else { break }
                    courtesyTime = candidate
                case .chord:
                    break scan
                default:
                    continue
                }
            }
        }
        guard !courtesyKeys.isEmpty || courtesyTime != nil else { return nil }
        return band(keys: courtesyKeys, time: courtesyTime, metrics: metrics)
    }

    /// Lay the announced columns out and size the band that holds them.
    ///
    /// Sized from what the RENDERERS actually draw, not from the header
    /// schedule's `sp * (glyphs + 1.5)` / `sp * 3` columns. Those are
    /// padded estimates that happen to work INSIDE a measure — an
    /// overrun there just eats into the next column — but this band ends
    /// at the system's right edge, where an overrun leaves the page. The
    /// header's arithmetic under-reserves from five accidentals up
    /// (seven sharps stride out 9.4 sp into an 8.5 sp column), so a real
    /// modulation to C♯ or G♭ spilled past `LayoutSystem.size.width`.
    private static func band(
        keys: [CourtesyKeySignature],
        time: CourtesyTimeSignature?,
        metrics: StaffMetrics,
    ) -> TrailingCourtesy {
        let gap = courtesyGap(sp: metrics.sp)
        var keyInk: CGFloat = 0
        for key in keys {
            // A change that lands on C draws the OUTGOING key's row as
            // naturals and nothing else, so its glyph count is that
            // key's — see `KeySignatureSteps.cancellationNaturals`.
            let glyphs = key.newKey != 0
                ? abs(key.newKey) : abs(key.priorKey)
            keyInk = max(
                keyInk,
                KeySignatureSteps.inkWidth(
                    glyphCount: glyphs, sp: metrics.sp,
                ),
            )
        }
        let timeInk: CGFloat = time.map {
            TimeSignatureLayout.inkWidth(
                numerator: $0.numerator,
                denominator: $0.denominator,
                symbol: $0.symbol,
                sp: metrics.sp,
            )
        } ?? 0
        // Half a glyph inside its column's left edge, because every
        // renderer centers a time-signature glyph on its stride — and a
        // symbol's glyph is not a digit's.
        let timeGlyphWidth = (time?.symbol ?? .numeric) == .numeric
            ? TimeSignatureLayout.digitWidth(sp: metrics.sp)
            : TimeSignatureLayout.symbolWidth(sp: metrics.sp)
        // Columns left to right, each preceded by a gap; the trailing pad
        // closes the band. A key-only or time-only announcement simply
        // drops the column it doesn't have, and with it that column's
        // gap.
        let timeColumnStart = keyInk > 0 ? gap + keyInk + gap : gap
        let lastColumnEnd = timeInk > 0
            ? timeColumnStart + timeInk
            : gap + keyInk
        return TrailingCourtesy(
            keys: keys,
            time: time,
            keyOriginDx: gap
                + KeySignatureSteps.glyphWidth(sp: metrics.sp) / 2,
            timeOriginDx: timeColumnStart + timeGlyphWidth / 2,
            width: lastColumnEnd + gap,
        )
    }

    /// The announcement's glyphs for one staff, in the same measure-local
    /// / staff-local coordinates `placeMeasureElements` emits.
    ///
    /// `contentWidth` is the measure's width WITHOUT the trailing
    /// reservation — i.e. where the end barline sits. MuseScore orders
    /// the trailer `EndBarLine, KeySigAnnounce, TimeSigAnnounce`
    /// (`engraving/dom/segment.h`), so the announcement follows the
    /// barline rather than preceding it, key first.
    static func courtesyElements(
        _ courtesy: TrailingCourtesy,
        staffIndex: Int,
        contentWidth: CGFloat,
        clef: NotatedClef,
        lineGeometry: StaffLineGeometry,
        metrics: StaffMetrics,
    ) -> [LayoutElement] {
        let staffMidY = metrics.staffHeight / 2 + metrics.sp * 2
        var out: [LayoutElement] = []
        if let key = courtesy.keys.first(where: {
            $0.staffIndex == staffIndex
        }) {
            out.append(.keySignature(
                sharps: max(0, key.newKey),
                flats: max(0, -key.newKey),
                clef: clef,
                // The naturals rule applies to an announcement exactly as
                // it does to the change itself — a courtesy of a change
                // to C is a row of naturals over the outgoing key.
                naturals: KeySignatureSteps.cancellationNaturals(
                    priorKey: key.priorKey,
                    newKey: key.newKey,
                    clef: clef,
                ),
                origin: CGPoint(
                    x: contentWidth + courtesy.keyOriginDx,
                    y: staffMidY,
                ),
            ))
        }
        if let time = courtesy.time {
            out.append(.timeSignature(
                numerator: time.numerator,
                denominator: time.denominator,
                symbol: time.symbol,
                origin: CGPoint(
                    x: contentWidth + courtesy.timeOriginDx,
                    y: staffMidY
                        + metrics.sp * lineGeometry.centerOffsetSp,
                ),
            ))
        }
        return out
    }
}
