import SheetMusicCore

/// MuseScore's "hide empty staves": which staves a system draws, given the measures it holds
/// (`SystemLayout::hideEmptyStaves`, `rendering/score/systemlayout.cpp:671-742`, called once per system after its
/// measures are collected, `:385`).
///
/// A staff decides by its mode (`computeHideMode`, `:545-600`): its own `Staff.hideWhenEmpty` if not `auto`, else its
/// part's `Part.hideWhenEmpty`, where `auto` follows the score's `ScoreStyle.hideEmptyStaves` — except in the first
/// system (of the score, or after a section break) while `dontHideStavesInFirstSystem` is on. A staff that may hide
/// stays when it is not empty in the system (`computeShowSysStaff`, `:602-669`): a staff spanner overlaps the system,
/// a measure of it holds content (`Measure::isEmpty`, `dom/measure.cpp:2448-2502`), or — when its part hides its staves
/// only together — another staff of the part holds content. A system left with no staff at all gets back its
/// `Staff.showIfSystemEmpty` staves, or else its first.
///
/// What this leaves out: MuseScore's per-measure `<hideIfEmpty>` overrides and `<cutaway>` (both kept as preserved
/// markup), and notes moved to another staff (`staffMove`), which this model does not have. The engine draws every
/// staff it is given, so a staff a host hides (`Score.filtered(hidingStaves:)`, MuseScore's `Staff::show()`) is gone
/// before this runs.
struct EmptyStaffHiding {
    private enum Mode {
        case alwaysShow, whenStaffEmpty, whenPartEmpty
    }

    private let score: Score
    private let addresses: [StaffAddress]
    private let staves: [Staff]
    /// The flat staff range of the part each flat staff belongs to.
    private let partRanges: [Range<Int>]
    /// Per flat staff, the measures each of its staff spanners reaches over.
    private let spannerSpans: [[ClosedRange<Int>]]
    private let plan: MultiMeasureRestPlan

    /// Nil when the host turned the behavior off, the score has a single staff, or no staff of it can ever hide —
    /// every system then draws every staff, with no work spent finding that out.
    init?(score: Score, options: ScoreViewOptions, plan: MultiMeasureRestPlan) {
        guard options.hidesEmptyStaves else { return nil }
        self.init(score: score, plan: plan)
    }

    init?(score: Score, plan: MultiMeasureRestPlan = MultiMeasureRestPlan()) {
        let allStaves = score.allStaves
        // One staff: shown, whatever its settings say (`systemlayout.cpp:678-684`).
        guard allStaves.count > 1 else { return nil }
        let mayHide = allStaves.contains { entry in
            Self.mode(
                staff: entry.staff, part: score.parts[entry.address.partIndex],
                globalHideIfEmpty: score.style.hideEmptyStaves,
            ) != .alwaysShow
        }
        guard mayHide else { return nil }
        self.score = score
        self.plan = plan
        addresses = allStaves.map(\.address)
        staves = allStaves.map(\.staff)
        var ranges: [Range<Int>] = []
        var start = 0
        for part in score.parts {
            let range = start ..< start + part.staves.count
            ranges.append(contentsOf: Array(repeating: range, count: part.staves.count))
            start = range.upperBound
        }
        partRanges = ranges
        spannerSpans = staves.map { Self.spannerSpans(in: $0, division: score.division) }
    }

    /// Whether each staff, in `Score.allStaves` order, is drawn in the system holding `measureRange`. Never all
    /// false. `isFirstSystem` is the score's first system or the first after a section break, the systems
    /// `dontHideStavesInFirstSystem` spares.
    func shownStaves(measureRange: Range<Int>, isFirstSystem: Bool) -> [Bool] {
        let style = score.style
        let globalHideIfEmpty = style.hideEmptyStaves && !(isFirstSystem && style.dontHideStavesInFirstSystem)
        var content = [Bool?](repeating: nil, count: staves.count)
        func hasContent(_ staffIdx: Int) -> Bool {
            if let known = content[staffIdx] { return known }
            let found = measureRange.contains { !isEmpty(staffIdx: staffIdx, measureIdx: $0) }
            content[staffIdx] = found
            return found
        }
        var shown = [Bool](repeating: true, count: staves.count)
        for staffIdx in staves.indices {
            let mode = Self.mode(
                staff: staves[staffIdx], part: score.parts[addresses[staffIdx].partIndex],
                globalHideIfEmpty: globalHideIfEmpty,
            )
            switch mode {
            case .alwaysShow:
                continue
            case .whenStaffEmpty:
                shown[staffIdx] = spannerOverlaps(staffIdx: staffIdx, measureRange: measureRange)
                    || hasContent(staffIdx)
            case .whenPartEmpty:
                // A sibling's spanners do not count, only its measures (`systemlayout.cpp:633-648`).
                shown[staffIdx] = spannerOverlaps(staffIdx: staffIdx, measureRange: measureRange)
                    || partRanges[staffIdx].contains { hasContent($0) }
            }
        }
        if !shown.contains(true) {
            for staffIdx in staves.indices where staves[staffIdx].showIfSystemEmpty {
                shown[staffIdx] = true
            }
            if !shown.contains(true) {
                shown[0] = true
            }
        }
        return shown
    }

    // MARK: - Mode

    private static func mode(staff: Staff, part: Part, globalHideIfEmpty: Bool) -> Mode {
        switch staff.hideWhenEmpty {
        case .on: return .whenStaffEmpty
        case .off: return .alwaysShow
        case .auto: break
        }
        switch part.hideWhenEmpty {
        case .on: break
        case .off: return .alwaysShow
        case .auto: if !globalHideIfEmpty { return .alwaysShow }
        }
        return part.hideStavesWhenIndividuallyEmpty ? .whenStaffEmpty : .whenPartEmpty
    }

    // MARK: - Spanners

    /// A spanner MuseScore keeps in the score's spanner map against a staff, as opposed to a system one (a volta, a
    /// gradual tempo change — `ElementFlag::SYSTEM`, `dom/volta.cpp:106`, `dom/gradualtempochange.cpp:113`), which
    /// keeps no staff from hiding. A text line made a system line (`<TextLine system="1">`) is not told apart here.
    static func isSystemSpanner(_ kind: Spanner.Kind) -> Bool {
        kind == .volta || kind == .gradualTempoChange
    }

    /// Whether a staff spanner of `staffIdx` reaches into the system. MuseScore asks the spanner map for every
    /// spanner overlapping the system's ticks and skips one that ends exactly where the system starts, unless it is a
    /// slur (`systemlayout.cpp:610-617`); `spannerSpans` already gives such a line its last measure as the one before
    /// the system, so a measure overlap answers the same.
    private func spannerOverlaps(staffIdx: Int, measureRange: Range<Int>) -> Bool {
        guard let last = measureRange.last else { return false }
        return spannerSpans[staffIdx].contains { $0.lowerBound <= last && $0.upperBound >= measureRange.lowerBound }
    }

    /// The measures each staff spanner of `staff` covers: every voice-level line, and every spanner a chord or grace
    /// chord starts (a slur). Hidden ones count — MuseScore's check does not look at visibility.
    ///
    /// The end comes from the same `<next><location>` reading the line spanners are drawn by (`endAnchor`), which
    /// gives a line ending on a barline the measure before it. A slur ends ON a chord, so one that lands on a barline
    /// belongs to the measure after: MuseScore keeps a staff for a slur whose end chord opens the system.
    private static func spannerSpans(in staff: Staff, division: Int) -> [ClosedRange<Int>] {
        let durations = staff.measures.effectiveMeasureDurations()
        var spans: [ClosedRange<Int>] = []
        func add(_ spanner: Spanner, measureIdx: Int, tick: Int) {
            guard !spanner.isEndMarker, !isSystemSpanner(spanner.kind) else { return }
            let end = LayoutEngine.endAnchor(
                startMeasureIdx: measureIdx, startTickInMeasure: tick,
                nextMeasuresOffset: spanner.nextMeasuresOffset, nextFractionsOffset: spanner.nextFractionsOffset,
                measures: staff.measures, measureDurations: durations, division: division,
            )
            var last = max(measureIdx, end.endMeasure)
            let fractionTicks = spanner.nextFractionsOffset?.ticks(division: division) ?? 0
            if spanner.kind == .slur, end.endTick == 0, spanner.nextMeasuresOffset > 0 || fractionTicks != 0 {
                last = min(last + 1, max(measureIdx, staff.measures.count - 1))
            }
            spans.append(measureIdx ... last)
        }
        for (measureIdx, measure) in staff.measures.enumerated() {
            let duration = durations.indices.contains(measureIdx)
                ? durations[measureIdx] : Fraction(numerator: 4, denominator: 4)
            for voice in measure.voices {
                // The voice cursor `collectSpanners` walks with, so a line starts in the measure it is drawn from.
                var tick = 0
                for element in voice.elements {
                    switch element {
                    case let .spanner(spanner):
                        add(spanner, measureIdx: measureIdx, tick: tick)
                    case let .chord(chord):
                        for spanner in chord.spanners {
                            add(spanner, measureIdx: measureIdx, tick: tick)
                        }
                        for grace in chord.graceNotesBefore.values + chord.graceNotesAfter.values {
                            for spanner in grace.spanners {
                                add(spanner, measureIdx: measureIdx, tick: tick)
                            }
                        }
                        tick += chord.duration.resolved(in: duration).ticks(division: division)
                    case let .locationShift(delta):
                        tick += delta.ticks(division: division)
                    default:
                        break
                    }
                }
            }
        }
        return spans
    }

    // MARK: - Emptiness

    /// MuseScore's `Measure::isEmpty(staffIdx)` (`dom/measure.cpp:2448-2502`): a measure of a multi-measure rest is
    /// empty; one in a measure-repeat group is not; otherwise only rests make it empty — a chord, hidden or not, does
    /// not — and a visible staff-bound annotation (a dynamic, a chord symbol, a staff text, an instrument change, …)
    /// makes it not empty. Fermatas, hidden annotations and system objects are passed over, and lyrics, clefs, key
    /// signatures and breaths are never looked at: they are not annotations of a chord-rest segment.
    private func isEmpty(staffIdx: Int, measureIdx: Int) -> Bool {
        if plan.run(containing: measureIdx) != nil { return true }
        let staff = staves[staffIdx]
        guard staff.measures.indices.contains(measureIdx) else { return true }
        let measure = staff.measures[measureIdx]
        if measure.measureRepeatCount != nil { return false }
        for voice in measure.voices {
            for element in voice.elements where Self.isContent(element) {
                return false
            }
        }
        guard score.systemMeasures.indices.contains(measureIdx) else { return true }
        let canonical = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        for positioned in score.systemMeasures[measureIdx].elements
            where !positioned.isScoreWide && (positioned.originalStaff ?? canonical) == addresses[staffIdx]
        {
            if Self.isVisible(positioned.element) { return false }
        }
        return true
    }

    /// Whether a voice element keeps its measure from being empty.
    private static func isContent(_ element: VoiceElement) -> Bool {
        switch element {
        case let .chord(chord): !chord.notes.isEmpty
        case .measureRepeat: true
        case let .dynamic(dynamic): dynamic.visible
        case let .harmony(harmony): harmony.visible
        case let .sticking(sticking): sticking.visible
        case let .expression(expression): expression.visible
        case let .capo(capo): capo.visible
        case let .stringTunings(tunings): tunings.visible
        case let .figuredBass(figuredBass): figuredBass.visible
        case let .symbol(symbol): symbol.visible
        case let .fretDiagram(diagram): diagram.visible
        // A fermata is skipped by name; the rest are not chord-rest annotations, or (`.spanner`) are asked about
        // through the spanner map instead. A voice child this model does not read is not looked into.
        case .keySignature, .timeSignature, .clef, .barLine, .spanner, .fermata, .breath, .ambitus, .preserved,
             .locationShift:
            false
        }
    }

    /// Visibility of a staff-bound system-lane element (`PositionedSystemElement.isScoreWide` false).
    private static func isVisible(_ element: SystemElement) -> Bool {
        switch element {
        case let .staffText(text): text.visible
        case let .swing(swing): swing.visible
        case let .instrumentChange(change): change.visible
        case .tempo, .rehearsalMark: false
        }
    }

    // MARK: - System objects

    /// The staff a system object written on flat staff `owner` is drawn on, or nil when it is not drawn —
    /// MuseScore's `EngravingItem::effectiveStaffIdx` (`dom/engravingitem.cpp:495-558`) for a score that names no
    /// system-object staff beyond the top one, so the object above `owner` is always the top staff's: an object on a
    /// shown staff stays, one on a hidden staff moves down to the next shown staff, and one below the top whose every
    /// staff above is hidden is dropped, since the top staff's copy has moved down to where it would be.
    ///
    /// With every staff shown it is `owner` itself.
    static func systemObjectStaff(owner: Int, staffCount: Int, isShown: (Int) -> Bool) -> Int? {
        guard owner >= 0, owner < staffCount else { return nil }
        if owner > 0, !(0 ..< owner).contains(where: isShown) { return nil }
        if isShown(owner) { return owner }
        return (owner + 1 ..< staffCount).first(where: isShown)
    }
}

extension LayoutEngine {
    /// The system lane of `measureIdx` dealt out to the flat staves that place it, in lane order: each element to the
    /// staff it was written on (`originalStaff`, the top staff when nil). A system object moves off a staff this
    /// system hides (`EmptyStaffHiding.systemObjectStaff`); a staff's own mark on a hidden staff is dropped with it;
    /// an element whose staff the score does not have is placed nowhere. With every staff shown, each staff gets
    /// exactly the elements written on it.
    static func systemElementsByStaff(
        measureIdx: Int, score: Score, addresses: [StaffAddress], isShown: (Int) -> Bool,
    ) -> [Int: [PositionedSystemElement]] {
        guard score.systemMeasures.indices.contains(measureIdx) else { return [:] }
        let canonical = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        var byStaff: [Int: [PositionedSystemElement]] = [:]
        for element in score.systemMeasures[measureIdx].elements {
            guard let owner = addresses.firstIndex(of: element.originalStaff ?? canonical) else { continue }
            let target = element.isScoreWide
                ? EmptyStaffHiding.systemObjectStaff(owner: owner, staffCount: addresses.count, isShown: isShown)
                : (isShown(owner) ? owner : nil)
            guard let target else { continue }
            byStaff[target, default: []].append(element)
        }
        return byStaff
    }

    /// `anchors` with every system spanner (a gradual tempo change; `EmptyStaffHiding.isSystemSpanner`) on a staff
    /// this system hides moved to the staff MuseScore draws it on, or dropped when it draws it on none. A staff
    /// spanner stays where it is: a staff it overlaps is never hidden, short of one ending at the system's start,
    /// which draws nothing here.
    static func movingSystemSpanners(
        _ anchors: [SpannerAnchor], staffCount: Int, isShown: (Int) -> Bool,
    ) -> [SpannerAnchor] {
        anchors.compactMap { anchor in
            guard EmptyStaffHiding.isSystemSpanner(anchor.kind) else { return anchor }
            guard let staff = EmptyStaffHiding.systemObjectStaff(
                owner: anchor.startStaff, staffCount: staffCount, isShown: isShown,
            ) else { return nil }
            var moved = anchor
            moved.startStaff = staff
            moved.endStaff = staff
            return moved
        }
    }

    /// The row of `system` a post-pass spanner (`attachSpanners`) on `anchor`'s staff is drawn on, or nil when it is
    /// drawn on none: its own staff's row, or for a system spanner (a volta) on a hidden staff the next shown one's.
    /// `addresses` is `Score.allStaves`' in order. With every staff shown it is `anchor.startStaff`.
    static func spannerRow(
        for anchor: SpannerAnchor, in system: LayoutSystem, addresses: [StaffAddress],
    ) -> Int? {
        guard EmptyStaffHiding.isSystemSpanner(anchor.kind) else {
            return system.flatIndex(for: anchor.staffAddress)
        }
        let shown = Set(system.staffAddresses)
        guard let staff = EmptyStaffHiding.systemObjectStaff(
            owner: anchor.startStaff, staffCount: addresses.count, isShown: { shown.contains(addresses[$0]) },
        ) else { return nil }
        return system.flatIndex(for: addresses[staff])
    }

    /// A bracket spanning flat staves `first ... last`, trimmed to the shown ones — or nil when it is not drawn
    /// (`SystemLayout::createBracket`, `rendering/score/systemlayout.cpp:2380-2408`). It is drawn when what is left
    /// spans more than one staff, spans as many as before, or is one staff and the style keeps such a bracket
    /// (`alwaysShowBracketsWhenHidingStaves`, or for a square one `alwaysShowSquareBracketsWhenHidingStaves`).
    /// `shownCount` is the shown staves it spans, which choose a brace's glyph (`Bracket::setStaffSpan`,
    /// `dom/bracket.cpp:63-96`). "Before" is the span clamped to the score's last staff, as MuseScore clamps it
    /// (`Staff::cleanupBrackets`, `dom/staff.cpp:520-533`).
    static func trimmedBracketSpan(
        _ bracket: BracketItem, from first: Int, to last: Int, isShown: (Int) -> Bool, style: ScoreStyle,
    ) -> (first: Int, last: Int, shownCount: Int)? {
        guard first <= last,
              let top = (first ... last).first(where: isShown),
              let bottom = (first ... last).last(where: isShown)
        else { return nil }
        let span = bottom - top + 1
        let keepsSingle = bracket.type == .square
            ? style.alwaysShowSquareBracketsWhenHidingStaves
            : style.alwaysShowBracketsWhenHidingStaves
        guard span > 1 || span == last - first + 1 || keepsSingle else { return nil }
        return (top, bottom, (top ... bottom).count(where: isShown))
    }

    /// Whether each staff of `score`, in `Score.allStaves` order, is drawn in the system holding `measureRange` —
    /// `EmptyStaffHiding.shownStaves(measureRange:isFirstSystem:)`, all true when nothing in the score can hide.
    static func shownStaves(
        score: Score, measureRange: Range<Int>, isFirstSystem: Bool,
        multiMeasureRestPlan: MultiMeasureRestPlan = MultiMeasureRestPlan(),
    ) -> [Bool] {
        EmptyStaffHiding(score: score, plan: multiMeasureRestPlan)?
            .shownStaves(measureRange: measureRange, isFirstSystem: isFirstSystem)
            ?? Array(repeating: true, count: score.allStaves.count)
    }
}
