#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// A chord's trailing grace notes: what they stand before on the staff, and how far left of it they reach.
///
/// MuseScore pre-appends a chord's after-graces to the next segment that holds anything on the staff
/// (`ChordLayout::appendGraceNotes`) — the next chord or rest in any voice, or the barline — and lays them out
/// against it as a leading group is laid out against its chord (`LayoutEngine+GraceGroup.swift`). Both passes
/// find that target here, from the bar itself: `aggregatedTickWeights` to give the group its room, and
/// `placeMeasureElements` to draw it.
extension LayoutEngine {
    /// One chord or rest of a staff's bar, at its column: what a trailing grace group can stand before.
    struct StaffColumnEntry: Equatable {
        let element: Chord
        /// A visible clef written in the same voice right before it, after the voice's first chord or rest — drawn
        /// small before the column (`midMeasureClefOffset`).
        let clefBefore: String?
    }

    /// One staff's bar, as its trailing grace groups see it.
    struct StaffColumns: Equatable {
        /// Tick → the chords and rests that start there, in voice order.
        var entries: [Int: [StaffColumnEntry]] = [:]
        /// The visible clefs written after a voice's last chord or rest, drawn small before the barline.
        var barEndClefs: [String] = []
        /// The subtype of a barline a voice writes after its last chord or rest; `nil` when none does.
        var trailingBarLineSubtype: String?

        /// The first column after `tick`; `nil` when none follows in the bar.
        func column(after tick: Int) -> Int? {
            entries.keys.filter { $0 > tick }.min()
        }
    }

    /// Whether any chord in `measure` has trailing graces: the one thing `staffColumns` is built for. Most measures
    /// have none, and asking is much cheaper than building the columns, which copies every chord in the measure.
    static func hasTrailingGraces(_ measure: Measure) -> Bool {
        measure.voices.contains { voice in
            voice.elements.contains { element in
                if case let .chord(chord) = element { return !chord.graceNotesAfter.isEmpty }
                return false
            }
        }
    }

    /// `measure`'s columns on its own staff, at the ticks `aggregatedTickWeights` and `placeMeasureElements` give them.
    static func staffColumns(of measure: Measure, measureDuration: Fraction, division: Int) -> StaffColumns {
        var columns = StaffColumns()
        for voice in measure.voices {
            var tick = 0
            var sawTimed = false
            var pendingClef: String?
            var barLine: BarLine?
            for element in voice.elements {
                switch element {
                case let .chord(chord):
                    columns.entries[tick, default: []].append(StaffColumnEntry(element: chord, clefBefore: pendingClef))
                    pendingClef = nil
                    barLine = nil
                    sawTimed = true
                    tick += chord.duration.resolved(in: measureDuration).ticks(division: division)
                case let .clef(clef) where sawTimed && clef.visible:
                    pendingClef = clef.concertClefType
                case let .barLine(bar) where sawTimed && bar.visible:
                    barLine = bar
                case let .breath(breath):
                    tick += breathReservationTicks(breath, division: division)
                case let .locationShift(delta):
                    tick += delta.ticks(division: division)
                default:
                    break
                }
            }
            if let pendingClef { columns.barEndClefs.append(pendingClef) }
            if let barLine { columns.trailingBarLineSubtype = barLine.subtype }
        }
        return columns
    }

    /// What `chord`'s trailing graces keep clear of when they stand before the column `entries` make up — relative to
    /// that column's x. A chord there with leading graces of its own is represented by them, as the group MuseScore
    /// merges the two into places them; they are taken where the spacing pass puts them (stems up), at or left of
    /// where they are drawn.
    static func afterGraceObstacles(
        before entries: [StaffColumnEntry], graceNoteMag mag: CGFloat, metrics: StaffMetrics,
    ) -> [GraceObstacle] {
        var out: [GraceObstacle] = []
        for entry in entries {
            let element = entry.element
            if let rawType = entry.clefBefore {
                let reach = midMeasureClefReach(rawType: rawType, before: element, graceNoteMag: mag, metrics: metrics)
                out.append(GraceObstacle(
                    kind: .clef, left: -(reach - midMeasureClefLeadSp * metrics.sp), steps: nil, mag: smallClefMag,
                ))
            }
            guard !element.notes.isEmpty else {
                let halfWidth = bravuraAdvance(RestGlyph.codepoint(duration: element.duration), metrics: metrics) / 2
                out.append(GraceObstacle(kind: .rest, left: -halfWidth, steps: nil))
                continue
            }
            out += obstacles(ofChord: element, metrics: metrics)
            let befores = Array(element.graceNotesBefore.values)
            for (grace, x) in zip(befores, beforeGraceOffsets(of: element, mag: mag, metrics: metrics)) {
                let ink = graceInk(of: grace, stem: nil, mag: mag, metrics: metrics)
                out += obstacles(ofGrace: grace, at: x, ink: ink, mag: mag, metrics: metrics)
            }
        }
        return out
    }

    /// What trailing graces keep clear of at the end of a bar — relative to the barline's x: the barline, and any clef
    /// drawn before it (`placeMeasureElements` puts a bar-end clef's right edge `sp / 2` left of the barline's x).
    static func afterGraceObstacles(
        atBarEndOf columns: StaffColumns, followingClef: String?, endsRepeat: Bool, metrics: StaffMetrics,
    ) -> [GraceObstacle] {
        let subtype = columns.trailingBarLineSubtype ?? (endsRepeat ? "end-repeat" : nil)
        var out = [GraceObstacle(
            kind: .barline, left: -BarLineGeometry.leftExtent(subtype: subtype, sp: metrics.sp), steps: nil,
        )]
        for rawType in columns.barEndClefs + [followingClef].compactMap(\.self) {
            out.append(GraceObstacle(
                kind: .clef, left: -(metrics.sp / 2 + smallClefAdvance(rawType: rawType, metrics: metrics)),
                steps: nil, mag: smallClefMag,
            ))
        }
        return out
    }

    /// The x of each of `chord`'s trailing graces, left to right, relative to the x `obstacles` are measured from.
    static func afterGraceOffsets(
        of chord: Chord, stems: [StemDirection]? = nil, clearing obstacles: [GraceObstacle], mag: CGFloat,
        metrics: StaffMetrics,
    ) -> [CGFloat] {
        graceGroupOffsets(
            Array(chord.graceNotesAfter.values), stems: stems, clearing: obstacles, mag: mag, metrics: metrics,
        )
    }

    /// How far left of the x `obstacles` are measured from `chord`'s trailing graces reach, plus the padding top-up
    /// against the chord they follow (`graceReachPaddingTopUpSp`). `0` with no graces.
    static func afterGraceReach(
        of chord: Chord, clearing obstacles: [GraceObstacle], mag: CGFloat, metrics: StaffMetrics,
    ) -> CGFloat {
        guard let first = chord.graceNotesAfter.values.first,
              let x = afterGraceOffsets(of: chord, clearing: obstacles, mag: mag, metrics: metrics).first
        else { return 0 }
        let ink = graceInk(of: first, stem: nil, mag: mag, metrics: metrics)
        return -x + ink.left + graceReachPaddingTopUpSp * metrics.sp
    }

    /// The ticks a breath mark takes on the spacing grid: a slot for its glyph, plus its pause at 120 BPM.
    ///
    /// TODO: multi-tempo scores — sample the tempo timeline at the breath's tick instead of hard-coding 2 beats a
    /// second.
    static func breathReservationTicks(_ breath: Breath, division: Int) -> Int {
        var ticks = 120
        if breath.pause > 0 {
            ticks += Int((breath.pause * 2.0 * Double(division)).rounded())
        }
        return ticks
    }
}
