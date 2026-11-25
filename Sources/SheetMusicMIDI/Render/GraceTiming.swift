import SheetMusicCore
import SheetMusicFoundation

/// Which of MuseScore's two rules places a chord's grace notes in time. MuseScore itself has both: what its MIDI export
/// writes is not what its playback sounds.
enum GraceTiming: Sendable {
    /// The MIDI export (`CompatMidiRender`): a slashed grace sounds before the beat, in time taken from the previous
    /// chord. A file a user exports keeps this, so it matches the file MuseScore writes.
    case smfExport
    /// MuseScore 4's playback (`GraceChordCtx`, `engraving/playback/renderers/gracechordcontext.cpp`): every grace
    /// note before the chord starts ON the beat and delays the chord, the slashed one included. What a synthesizer
    /// plays.
    case performance
}

/// Where a chord's grace notes sound, as ticks from the chord's own onset.
struct GraceLayout: Equatable {
    struct Slot: Equatable {
        var offset: Int
        var ticks: Int
    }

    var before: [Slot]
    var after: [Slot]
    /// What the previous chord loses at its tail, the chord at its head and the chord at its tail.
    var stealFromPrev: Int
    var stealFromHead: Int
    var stealFromTail: Int
}

extension MidiRenderer {
    /// `chord`'s grace notes placed by `timing`. `tick` is the chord's onset, `mainTicks` how long it sounds with no
    /// grace notes, `isCompoundMeter` whether it stands in 6/8, 9/8, 12/8 and the like.
    static func graceLayout(
        for chord: Chord, timing: GraceTiming, tick: Int, mainTicks: Int, division: Int, isCompoundMeter: Bool,
    ) -> GraceLayout {
        let before = chord.graceNotesBefore.values
        let after = chord.graceNotesAfter.values
        switch timing {
        case .smfExport:
            return exportedGraceLayout(
                before: before, after: after, tick: tick, mainTicks: mainTicks, division: division,
            )
        case .performance:
            let beforeTicks = performedGraceTicks(
                before, isBefore: true, mainTicks: mainTicks, division: division, isCompoundMeter: isCompoundMeter,
            )
            let head = beforeTicks.reduce(0, +)
            // A chord with both shares itself out: what follows it takes its part of what the first group left.
            let afterTicks = performedGraceTicks(
                after, isBefore: false, mainTicks: mainTicks - head, division: division,
                isCompoundMeter: isCompoundMeter,
            )
            let tail = afterTicks.reduce(0, +)
            return GraceLayout(
                before: consecutiveSlots(beforeTicks, from: 0),
                after: consecutiveSlots(afterTicks, from: head + max(1, mainTicks - head - tail)),
                stealFromPrev: 0, stealFromHead: head, stealFromTail: tail,
            )
        }
    }

    /// The lengths MuseScore 4 plays a group of grace notes at: their written lengths, squeezed in proportion into the
    /// time the chord gives up. A lone unslashed grace before the chord, or any after it, may take half of the chord —
    /// two thirds in a compound meter, when the chord is longer than an eighth. A slashed grace, or a run of several,
    /// gets a sixty-fourth note each, up to half of the chord.
    private static func performedGraceTicks(
        _ graces: [GraceChord], isBefore: Bool, mainTicks: Int, division: Int, isCompoundMeter: Bool,
    ) -> [Int] {
        guard !graces.isEmpty, mainTicks > 1 else { return graces.map { _ in 0 } }
        let written = graces.map { max(1, $0.duration.ticks(division: division)) }
        let total = written.reduce(0, +)
        let isLeaning = !isBefore || (graces.count == 1 && graces[0].graceType != .acciaccatura)
        let available: Int = if isLeaning {
            isCompoundMeter && mainTicks > division / 2 ? mainTicks * 2 / 3 : mainTicks / 2
        } else {
            min(max(1, division / 16) * graces.count, mainTicks / 2)
        }
        let played = min(available, total)
        // Rounded at the running edge, so the group fills exactly what it takes.
        var elapsed = 0
        return written.map { ticks in
            let start = elapsed * played / total
            elapsed += ticks
            return elapsed * played / total - start
        }
    }

    private static func exportedGraceLayout(
        before: [GraceChord], after: [GraceChord], tick: Int, mainTicks: Int, division: Int,
    ) -> GraceLayout {
        let stealFromPrev = totalStealFromPrev(before, division: division)
        let stealFromHead = totalStealFromMainHead(before, mainTicks: mainTicks, division: division)
        let stealFromTail = totalStealFromMainTail(after, mainTicks: mainTicks, division: division)
        // Two independent cursors so an acciaccatura order-mixed with non-acciaccaturas still lands in the correct
        // steal-region:
        //   prevCursor walks the [tick - stealFromPrev, tick) slot
        //   headCursor walks the [tick, tick + stealFromHead) slot
        var prevCursor = max(0, tick - stealFromPrev) - tick
        var headCursor = 0
        let beforeSlots = before.map { grace -> GraceLayout.Slot in
            let ticks = playbackTicks(for: grace, mainTicks: mainTicks, division: division)
            if grace.graceType == .acciaccatura {
                defer { prevCursor += ticks }
                return GraceLayout.Slot(offset: prevCursor, ticks: ticks)
            }
            defer { headCursor += ticks }
            return GraceLayout.Slot(offset: headCursor, ticks: ticks)
        }
        let afterTicks = after.map { playbackTicks(for: $0, mainTicks: mainTicks, division: division) }
        return GraceLayout(
            before: beforeSlots,
            after: consecutiveSlots(
                afterTicks, from: stealFromHead + max(1, mainTicks - stealFromHead - stealFromTail),
            ),
            stealFromPrev: stealFromPrev, stealFromHead: stealFromHead, stealFromTail: stealFromTail,
        )
    }

    private static func consecutiveSlots(_ ticks: [Int], from start: Int) -> [GraceLayout.Slot] {
        var offset = start
        return ticks.map { length in
            defer { offset += length }
            return GraceLayout.Slot(offset: offset, ticks: length)
        }
    }
}
