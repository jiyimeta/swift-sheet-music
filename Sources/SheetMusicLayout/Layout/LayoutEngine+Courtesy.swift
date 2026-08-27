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
    }

    /// Everything the trailing edge of one system announces, plus the
    /// width that announcement occupies.
    ///
    /// The width is stored rather than recomputed because two passes
    /// consume it and they must agree exactly: `packSystems` reserves it
    /// when it decides where the system ends, and `buildSystem`
    /// subtracts it again to recover the measure's content width.
    struct TrailingCourtesy: Equatable, Sendable {
        /// Only the staves whose key actually changes, so a change on
        /// one staff of a multi-staff score doesn't announce on the
        /// others.
        let keys: [CourtesyKeySignature]
        let time: CourtesyTimeSignature?
        /// Gap + key column. The time signature is drawn at
        /// `contentWidth + keyWidth`.
        let keyWidth: CGFloat
        /// Total trailing reservation: `keyWidth` + the time column.
        let width: CGFloat
    }

    /// Gap between the end barline and the first announced glyph.
    private static func courtesyLeadingGap(sp: CGFloat) -> CGFloat {
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
        // Same column arithmetic `computeHeaderSchedule` uses for the
        // leading header, so an announcement and the signature it
        // announces reserve the same room: `sp * (glyphs + 1.5)` for the
        // key, `sp * 3` for the time signature. A change that lands on C
        // draws the outgoing key's row as naturals, so it is as wide as
        // that key was.
        var keyWidth: CGFloat = 0
        for key in courtesyKeys {
            let glyphs = key.newKey != 0
                ? abs(key.newKey) : abs(key.priorKey)
            keyWidth = max(
                keyWidth, metrics.sp * (CGFloat(glyphs) + 1.5),
            )
        }
        let gap = courtesyLeadingGap(sp: metrics.sp)
        let timeWidth: CGFloat = courtesyTime != nil ? metrics.sp * 3 : 0
        return TrailingCourtesy(
            keys: courtesyKeys,
            time: courtesyTime,
            keyWidth: gap + keyWidth,
            width: gap + keyWidth + timeWidth,
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
                    x: contentWidth
                        + courtesyLeadingGap(sp: metrics.sp),
                    y: staffMidY,
                ),
            ))
        }
        if let time = courtesy.time {
            out.append(.timeSignature(
                numerator: time.numerator,
                denominator: time.denominator,
                origin: CGPoint(
                    x: contentWidth + courtesy.keyWidth,
                    y: staffMidY
                        + metrics.sp * lineGeometry.centerOffsetSp,
                ),
            ))
        }
        return out
    }
}
