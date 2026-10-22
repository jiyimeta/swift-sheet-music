import SheetMusicFoundation

/// How a measure repeat travels through a copy, a duplicate and a paste — MuseScore's rules, read off its paste
/// (`Read460::pasteStaff`, the `MeasureRepeat` branch, and `paste.cpp`):
///
/// - The `%` sign is a rest of its bar's length (`MeasureRepeat : Rest`), so a range takes it in and the copy carries
///   it. It travels in `RangeCopySource.Stream.elements` as the measure rest it stands for — the placement cuts and
///   re-spells chords and rests, and a sign landing mid-bar is exactly what it must turn into a rest anyway — and its
///   group travels beside the elements as a `RangeCopySource.CopiedMeasureRepeat`.
/// - At the destination the group comes back only where it lands on a barline and every bar it spans is as long as
///   the bar it was copied from. Anywhere else the rests stay, as MuseScore pastes a misaligned repeat as rests.
/// - A destination group the paste writes into is dissolved first, as MuseScore removes the repeat a paste lands on
///   before writing: the paste replaces the bar's content, and a sign left standing over the written material is the
///   sign-beside-a-rest shape no edit should leave behind.
///
/// Only a group the range covers whole travels: its sign alone does not say what the bars after it held.
extension RangeCopySource {
    /// A measure-repeat group the range covers whole, on the SOURCE staff's absolute tick axis: where its first bar
    /// starts, and how long each of its bars is.
    struct CopiedMeasureRepeat: Equatable {
        let absoluteTick: Int
        let barTicks: [Int]
    }

    /// The group whose sign stands at `id`, when the range `range` covers every bar of it. `nil` for a sign in an
    /// upper voice (a measure repeat is one voice), a sign whose bar is in no group, a group whose bars do not number
    /// `1…n` in a row, and a group the range covers only partly.
    ///
    /// The group's first bar is found from the sign's own bar, since `Measure.measureRepeatCount` numbers the bars
    /// `1…n` and MuseScore anchors the sign in a middle bar of a 2- or 4-bar group.
    static func copiedMeasureRepeat(
        signAt id: VoiceElementID, sign: MeasureRepeat, geometry: RangeCopyGeometry, score: Score, range: Range<Int>,
    ) -> CopiedMeasureRepeat? {
        guard id.voiceIndex == 0,
              let position = score[measure: MeasureRef(measureIndex: id.measureIndex), staff: id.staff]?
                  .measureRepeatCount
        else { return nil }
        let first = id.measureIndex - (position - 1)
        let bars = first ..< first + sign.numMeasures
        let numbered = bars.allSatisfy { index in
            geometry.measureStarts.indices.contains(index)
                && score[measure: MeasureRef(measureIndex: index), staff: id.staff]?.measureRepeatCount
                == index - first + 1
        }
        guard numbered, let firstBar = bars.first else { return nil }
        let start = geometry.measureStarts[firstBar]
        let barTicks = bars.map(geometry.measureLength)
        guard start >= range.lowerBound, start + barTicks.reduce(0, +) <= range.upperBound else { return nil }
        return CopiedMeasureRepeat(absoluteTick: start, barTicks: barTicks)
    }
}

extension RangeCopyWriting {
    /// Dissolves every measure-repeat group on `staves` with a bar in `[start, end)` — the destination span — back
    /// into measure rests, whole, before anything is written there.
    func dissolveMeasureRepeats(
        across staves: [StaffAddress], from start: Int, upTo end: Int,
        in scratch: inout Score, ids: inout EIDAllocator, commands: inout [any EditCommand],
    ) throws {
        for staff in staves {
            let geometry = RangeCopyGeometry(staff: staff, in: scratch)
            var groupStarts: [Int] = []
            for index in geometry.measureStarts.indices {
                let barStart = geometry.measureStarts[index]
                guard barStart < end, barStart + geometry.measureLength(index) > start,
                      let position = scratch[measure: MeasureRef(measureIndex: index), staff: staff]?
                          .measureRepeatCount
                else { continue }
                let first = index - (position - 1)
                if !groupStarts.contains(first) { groupStarts.append(first) }
            }
            for first in groupStarts {
                let command = SetMeasureRepeat(at: MeasureRef(measureIndex: first), staff: staff, numMeasures: nil)
                _ = try command.apply(to: &scratch, ids: &ids)
                commands.append(command)
            }
        }
    }

    /// Puts each copied group back where it landed on a barline over bars as long as its own, once every stream is
    /// written. A group `SetMeasureRepeat` refuses there — a bar whose upper voice holds more than notes and rests —
    /// keeps the rests the paste wrote, as a misaligned one does.
    func restoreMeasureRepeats(
        of source: RangeCopySource, at destinationTick: Int,
        in scratch: inout Score, ids: inout EIDAllocator, commands: inout [any EditCommand],
    ) {
        for stream in source.streams {
            for group in stream.measureRepeats {
                let geometry = RangeCopyGeometry(staff: stream.staff, in: scratch)
                let landing = destinationTick + group.absoluteTick - source.startTick
                guard let position = geometry.position(atAbsolute: landing), position.tick == 0,
                      group.barTicks.indices.allSatisfy({ offset in
                          geometry.measureStarts.indices.contains(position.measure + offset)
                              && geometry.measureLength(position.measure + offset) == group.barTicks[offset]
                      })
                else { continue }
                let command = SetMeasureRepeat(
                    at: MeasureRef(measureIndex: position.measure), staff: stream.staff,
                    numMeasures: group.barTicks.count,
                )
                // `SetMeasureRepeat` refuses before it writes or mints anything, so a refusal leaves both untouched.
                guard (try? command.apply(to: &scratch, ids: &ids)) != nil else { continue }
                commands.append(command)
            }
        }
    }
}
