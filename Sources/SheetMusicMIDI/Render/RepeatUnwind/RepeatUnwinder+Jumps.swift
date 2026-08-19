import SheetMusicCore
import SheetMusicFoundation

/// Jump / marker (D.C. / D.S. / Fine / Coda) handling for
/// `RepeatUnwinder`. Swift reimplementation — studied from, not
/// copied from — the jump/marker portion of
/// `mu::engraving::RepeatList::unwind` (repeatlist.cpp:957-1096) and
/// `RepeatList::performJump` (repeatlist.cpp:785-830).
extension RepeatUnwinder {
    /// JUMP (repeatlist.cpp:957-1060). A jump is honored only on the
    /// final playthrough of its measure and taken at most once per
    /// playbackCount.
    mutating func processJump(_ element: RepeatListElement) {
        guard let jump = element.jump else { return }
        let position = RepeatListPosition(section: sectionIndex, element: elementIndex)
        if activeJumpPosition == position {
            // Re-reached the jump we just took: its forced final
            // repeat extends only up to this point (repeat23,
            // repeatlist.cpp:958-963).
            forceFinalRepeat = false
        }
        let loopPlays = sections[sectionIndex][startRepeatIndex].repeatCount
        let isFinalPlaythrough = playbackCount >= loopPlays
            || activeVolta.map { playbackCount == $0.lastEnding } ?? false
        guard isFinalPlaythrough else { return }
        let occurrence = JumpOccurrence(
            position: position, playbackCount: playbackCount,
        )
        guard !jumpsTaken.contains(occurrence) else { return }
        jumpsTaken.insert(occurrence)

        // All three targets resolve before execution — playUntil /
        // continueAt stay armed even when jumpTo is unresolvable
        // (mirrors repeatlist.cpp:976-980).
        let jumpTo = RepeatListBuilder.findMarker(
            label: jump.jumpTo, from: position, in: sections,
        )
        playUntil = RepeatListBuilder.findMarker(
            label: jump.playUntil, from: position, in: sections,
        )
        continueAt = RepeatListBuilder.findMarker(
            label: jump.continueAt, from: position, in: sections,
        )
        guard let jumpTo else { return } // incomplete jump: carry on (repeat13)

        if let r = run, !r.isEmpty { runs.append(r) }
        run = nil
        activeJumpPosition = position
        performJump(to: jumpTo, withRepeats: jump.playRepeats)
        forceFinalRepeat = !jump.playRepeats
        if playUntil != nil {
            reevaluateRepeatCountsAfterJump()
        }
        if activeVolta != nil {
            reevaluateVoltasAfterJump()
        }
        run = MeasureRun(
            playbackCount: playbackCount,
            firstMeasure: sections[sectionIndex][elementIndex].measureIndex,
        )
    }

    /// Marker element (repeatlist.cpp:1061-1095): when this marker is the
    /// armed playUntil target on its final playthrough, close the run
    /// and continue at the continueAt target — or abandon the section
    /// when there is none. Returns false when the section is
    /// abandoned.
    mutating func processMarker(_: RepeatListElement) -> Bool {
        let position = RepeatListPosition(section: sectionIndex, element: elementIndex)
        guard position == playUntil else { return true }
        let loopPlays = sections[sectionIndex][startRepeatIndex].repeatCount
        let isFinalPlaythrough = playbackCount == loopPlays
            || activeVolta.map { playbackCount == $0.lastEnding } ?? false
        guard isFinalPlaythrough else { return true }
        if let r = run, !r.isEmpty { runs.append(r) }
        run = nil
        playUntil = nil
        forceFinalRepeat = false
        guard let target = continueAt else {
            // Nowhere to continue: abandon the rest of this section
            // (repeatlist.cpp:1091-1094).
            elementIndex = sections[sectionIndex].count
            return false
        }
        performJump(to: target, withRepeats: true)
        // The continueAt target becomes the loop-start reference
        // unless it sits on the measure the reference already points
        // at (repeat23 m12, repeatlist.cpp:1079-1084).
        if sections[sectionIndex][startRepeatIndex].measureIndex
            != sections[target.section][target.element].measureIndex
        {
            startRepeatIndex = target.element
        }
        run = MeasureRun(
            playbackCount: playbackCount,
            firstMeasure: sections[sectionIndex][elementIndex].measureIndex,
        )
        continueAt = nil
        return true
    }

    /// Fast-forward through the target's section up to the target
    /// element, deriving activeVolta / loop-start reference /
    /// playbackCount as a player arriving there would hold them
    /// (repeatlist.cpp:785-830).
    mutating func performJump(to target: RepeatListPosition, withRepeats: Bool) {
        let section = sections[target.section]
        activeVolta = nil
        startRepeatIndex = 0
        var index = 0
        while index < target.element {
            switch section[index].kind {
            case .voltaStart: activeVolta = section[index].volta
            case .voltaEnd: activeVolta = nil
            case .repeatStart: startRepeatIndex = index
            default: break
            }
            index += 1
        }
        if withRepeats {
            if let volta = activeVolta, volta.firstEnding != 0 {
                playbackCount = volta.firstEnding
            } else {
                playbackCount = 1
            }
        } else {
            if let volta = activeVolta, volta.lastEnding != 0 {
                playbackCount = volta.lastEnding
            } else {
                playbackCount = section[startRepeatIndex].repeatCount
            }
        }
        sectionIndex = target.section
        elementIndex = target.element
    }

    /// After a jump with an end target, reset each ALREADY-PLAYED
    /// end-repeat between the target and the section end: cleared for
    /// playRepeats (replay in full), re-armed to the full notated
    /// count when the jump forces final-pass playback (repeat22,
    /// repeatlist.cpp:996-1010).
    mutating func reevaluateRepeatCountsAfterJump() {
        var index = elementIndex + 1
        while index < sections[sectionIndex].count {
            if sections[sectionIndex][index].kind == .repeatEnd,
               sections[sectionIndex][index].repeatCount != 0
            {
                sections[sectionIndex][index].repeatCount = 0
                if forceFinalRepeat {
                    let measureIndex = sections[sectionIndex][index].measureIndex
                    sections[sectionIndex][index].repeatCount =
                        navigation.measures[measureIndex].endRepeatCount ?? 2
                }
            }
            index += 1
        }
    }

    /// After jumping INTO a volta that is not the loop's final pass,
    /// re-derive each end-repeat's hit count from the volta passes
    /// still to come (repeat52/53, repeatlist.cpp:1011-1052).
    mutating func reevaluateVoltasAfterJump() {
        let loopPlays = sections[sectionIndex][startRepeatIndex].repeatCount
        guard playbackCount < loopPlays else { return }
        var voltaReference: ScoreNavigation.VoltaSpan?
        var processedRepeatCount = 1
        var index = startRepeatIndex + 1
        while index < sections[sectionIndex].count,
              sections[sectionIndex][index].kind != .repeatStart,
              processedRepeatCount < loopPlays
        {
            let element = sections[sectionIndex][index]
            if element.kind == .voltaStart {
                voltaReference = element.volta
                if let volta = voltaReference, volta.lastEnding < playbackCount {
                    // This volta won't be passed again.
                    voltaReference = nil
                }
            } else if element.kind == .repeatEnd {
                let notatedPlays =
                    navigation.measures[element.measureIndex].endRepeatCount ?? 2
                if let volta = voltaReference {
                    let remaining = volta.endings.count(where: { $0 >= playbackCount })
                    sections[sectionIndex][index].repeatCount =
                        notatedPlays - remaining - 1
                }
                processedRepeatCount += notatedPlays - 1
            }
            index += 1
        }
    }
}
