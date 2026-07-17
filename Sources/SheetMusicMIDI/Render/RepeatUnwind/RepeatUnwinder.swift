import Foundation
import SheetMusicCore

/// Unrolls a `ScoreNavigation` into the flat measure-play order,
/// honoring start/end repeats, voltas and section breaks (jump /
/// marker handling lands in `RepeatUnwinder+Jumps.swift`). Swift
/// reimplementation — studied from, not copied from —
/// `mu::engraving::RepeatList::unwind` (repeatlist.cpp:835-1117).
///
/// This intentionally diverges from the deleted hand-rolled
/// `playbackPlan` on two exotic shapes — sequential repeat groups with
/// voltas (the old `take` counter never reset per group, so it could
/// wrongly skip a volta) and a skipped volta containing an
/// `endRepeat` (the old walk counted it; this one jumps straight to
/// `.voltaEnd`) — both now match MuseScore, so don't "restore" the
/// old behavior (see `PlaybackUnwindTests`).
struct RepeatUnwinder {
    /// One contiguous run of measure indices played in notated order.
    /// Analog of MuseScore's `RepeatSegment` (repeatlist.cpp:45-135).
    struct MeasureRun: Equatable {
        var playbackCount: Int
        var measures: [Int]

        init(playbackCount: Int, firstMeasure: Int) {
            self.playbackCount = playbackCount
            measures = [firstMeasure]
        }

        /// Mirrors `RepeatSegment::addMeasures` (repeatlist.cpp:63-80):
        /// fill forward, or clip back, so the run ends exactly at
        /// `measureIndex`.
        mutating func extend(through measureIndex: Int) {
            if !measures.isEmpty {
                var next = measures[measures.count - 1] + 1
                while next < measureIndex {
                    measures.append(next)
                    next += 1
                }
                while let last = measures.last, last >= measureIndex {
                    measures.removeLast()
                }
            }
            if measures.last != measureIndex {
                measures.append(measureIndex)
            }
        }

        mutating func popLast() {
            if !measures.isEmpty { measures.removeLast() }
        }

        var isEmpty: Bool {
            measures.isEmpty
        }
    }

    /// Identity of one taken jump: a jump is honored at most once per
    /// playbackCount (repeatlist.cpp:970-974).
    struct JumpOccurrence: Hashable {
        var position: RepeatListPosition
        var playbackCount: Int
    }

    let navigation: ScoreNavigation
    /// Mutable during unwinding: `.repeatEnd` elements count hits and
    /// get re-armed after jumps.
    var sections: [[RepeatListElement]]
    var runs: [MeasureRun] = []

    // Unwind state (repeatlist.cpp:849-872). Jumps mutate it across
    // sections, so it lives on the struct rather than in loop scope.
    var sectionIndex = 0
    var elementIndex = 0
    var playbackCount = 1
    /// Index (into the CURRENT section) of the loop-start reference.
    var startRepeatIndex = 0
    var activeVolta: ScoreNavigation.VoltaSpan?
    var playUntil: RepeatListPosition?
    var continueAt: RepeatListPosition?
    /// Position of the most recently taken jump — re-reaching it ends
    /// its forced-final-repeat scope (repeat23).
    var activeJumpPosition: RepeatListPosition?
    var forceFinalRepeat = false
    var run: MeasureRun?
    var jumpsTaken: Set<JumpOccurrence> = []

    init(navigation: ScoreNavigation) {
        self.navigation = navigation
        sections = RepeatListBuilder.collectElements(navigation: navigation)
    }

    /// The unrolled playback plan for `navigation`.
    static func plan(navigation: ScoreNavigation) -> [MidiRenderer.PlaybackEntry] {
        var unwinder = RepeatUnwinder(navigation: navigation)
        unwinder.unwind()
        return flatten(runs: unwinder.runs, navigation: navigation)
    }

    mutating func unwind() {
        guard !sections.isEmpty else { return }
        // Safety valve — the C++ has no equivalent, but our permissive
        // parser can load navigation graphs MuseScore's editor would
        // never produce; never spin forever.
        var steps = 0
        let maxSteps = (navigation.measures.count + 1) * 64
        while sectionIndex < sections.count {
            resetSectionState()
            while elementIndex < sections[sectionIndex].count {
                steps += 1
                if steps > maxSteps {
                    if let r = run, !r.isEmpty { runs.append(r) }
                    return
                }
                if processCurrentElement() {
                    elementIndex += 1
                }
            }
            sectionIndex += 1
        }
    }

    /// Per-section state reset (repeatlist.cpp:864-876). Element 0 is
    /// the section's implicit `.repeatStart`.
    private mutating func resetSectionState() {
        playbackCount = 1
        startRepeatIndex = 0
        activeVolta = nil
        playUntil = nil
        continueAt = nil
        forceFinalRepeat = false
        run = MeasureRun(
            playbackCount: playbackCount,
            firstMeasure: sections[sectionIndex][0].measureIndex,
        )
        elementIndex = 1
    }

    /// Handle one element. Returns false when the driver must NOT
    /// advance `elementIndex` (an honored repeat rewound to its start;
    /// a dead-end playUntil abandoned the section).
    private mutating func processCurrentElement() -> Bool {
        let element = sections[sectionIndex][elementIndex]
        run?.extend(through: element.measureIndex)
        switch element.kind {
        case .sectionBreak:
            if let r = run, !r.isEmpty { runs.append(r) }
            return true
        case .voltaStart:
            processVoltaStart(element)
            return true
        case .voltaEnd:
            activeVolta = nil
            return true
        case .repeatStart:
            processRepeatStart(element)
            return true
        case .repeatEnd:
            return processRepeatEnd(element)
        case .jump, .marker:
            // Inert until RepeatUnwinder+Jumps lands (nothing sets
            // playUntil / takes jumps yet).
            return true
        }
    }

    /// VOLTA_START (repeatlist.cpp:888-911): take the volta when the
    /// current playbackCount is among its endings; otherwise skip its
    /// measures and restart a run after it.
    private mutating func processVoltaStart(_ element: RepeatListElement) {
        guard let volta = element.volta else { return }
        activeVolta = volta
        guard !volta.hasEnding(playbackCount) else { return }
        run?.popLast()
        if let r = run, !r.isEmpty { runs.append(r) }
        while sections[sectionIndex][elementIndex].kind != .voltaEnd {
            elementIndex += 1
        }
        activeVolta = nil
        let voltaEndMeasure = sections[sectionIndex][elementIndex].measureIndex
        // C++ restarts on `nextMeasure()` and relies on null at score
        // end; we additionally clamp to the CURRENT section so a volta
        // ending a mid-score section can't leak the next section's
        // first measure into this one (deviation, same outcome for
        // repeat57/68).
        let sectionEnd = sections[sectionIndex][sections[sectionIndex].count - 1].measureIndex
        if voltaEndMeasure < sectionEnd {
            run = MeasureRun(
                playbackCount: playbackCount,
                firstMeasure: voltaEndMeasure + 1,
            )
        } else {
            run = nil // section break still closes out with no run
        }
    }

    /// REPEAT_START (repeatlist.cpp:915-933).
    private mutating func processRepeatStart(_ element: RepeatListElement) {
        if run == nil {
            // Sent here by an honored end-repeat's rewind.
            run = MeasureRun(
                playbackCount: playbackCount,
                firstMeasure: element.measureIndex,
            )
        } else {
            let desired = forceFinalRepeat ? element.repeatCount : 1
            if run?.playbackCount != desired {
                // New playbackCount reference: restart the run here.
                run?.popLast()
                if let r = run, !r.isEmpty { runs.append(r) }
                playbackCount = desired
                run = MeasureRun(
                    playbackCount: playbackCount,
                    firstMeasure: element.measureIndex,
                )
            }
            startRepeatIndex = elementIndex
        }
    }

    /// REPEAT_END (repeatlist.cpp:934-956). Returns false after a
    /// rewind so the driver re-evaluates the loop-start element.
    private mutating func processRepeatEnd(_ element: RepeatListElement) -> Bool {
        sections[sectionIndex][elementIndex].repeatCount += 1
        let hits = sections[sectionIndex][elementIndex].repeatCount
        let loopPlays = sections[sectionIndex][startRepeatIndex].repeatCount
        let notatedPlays = navigation.measures[element.measureIndex].endRepeatCount ?? 2
        guard playbackCount < loopPlays, hits < notatedPlays else { return true }
        if let r = run, !r.isEmpty { runs.append(r) }
        run = nil
        repeat {
            elementIndex -= 1
            let passed = sections[sectionIndex][elementIndex]
            if passed.kind == .voltaStart {
                activeVolta = nil
            } else if passed.kind == .voltaEnd {
                activeVolta = passed.volta
            }
        } while elementIndex != startRepeatIndex
        playbackCount += 1
        return false
    }

    /// Flatten runs into `PlaybackEntry`s with cumulative tick
    /// offsets from the navigation's canonical spans.
    /// `isIterationStart` marks any entry that doesn't continue
    /// linearly from its predecessor — loop-backs, jump/continueAt
    /// targets and volta skips. (The legacy walk flagged only
    /// loop-backs; the superset is inert downstream because
    /// `renderVoice`'s fresh-section re-emit also requires
    /// `measureIndex == 0 && tickOffset > 0`.)
    static func flatten(
        runs: [MeasureRun], navigation: ScoreNavigation,
    ) -> [MidiRenderer.PlaybackEntry] {
        var entries: [MidiRenderer.PlaybackEntry] = []
        var tick = 0
        var previousMeasure: Int?
        for run in runs {
            for measureIndex in run.measures
                where measureIndex < navigation.measures.count
            {
                let isJumpOrLoopTarget =
                    previousMeasure.map { measureIndex != $0 + 1 } ?? false
                entries.append(MidiRenderer.PlaybackEntry(
                    measureIndex: measureIndex,
                    tickOffset: tick,
                    isIterationStart: isJumpOrLoopTarget,
                ))
                tick += navigation.measures[measureIndex].tickSpan
                previousMeasure = measureIndex
            }
        }
        return entries
    }
}
