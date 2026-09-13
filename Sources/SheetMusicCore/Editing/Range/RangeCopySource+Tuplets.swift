import SheetMusicFoundation

/// What the source side has to know about the tuplets a range touches: which elements stand under a bracket,
/// and which brackets travel with the copy.
///
/// Tuplets live on the (per-measure) `Voice`, so both walks below visit the distinct measures the stream's own
/// chords touched. Split from `RangeCopySource` for the file-length budget.
extension RangeCopySource {
    /// Every element location that stands under a tuplet bracket — the set the range-end clamp exempts.
    ///
    /// Every member, not only the last one: which member the range's far edge cuts is not knowable here, and a
    /// member is exempt wherever it sits. A dangling endpoint resolves to -1 and names no member at all.
    static func tupletMemberLocations(
        for ids: [VoiceElementID], staff: StaffAddress, voiceIndex: Int, score: Score,
    ) -> Set<MeasureElementLocation> {
        var measureOrder: [Int] = []
        for id in ids where !measureOrder.contains(id.measureIndex) {
            measureOrder.append(id.measureIndex)
        }

        var members: Set<MeasureElementLocation> = []
        for measureIndex in measureOrder {
            let ref = VoiceRef(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
            guard let voice = score[voice: ref] else { continue }
            for span in voice.tupletSpans where span.startIndex >= 0 && span.startIndex <= span.endIndex {
                for index in span.startIndex ... span.endIndex {
                    members.insert(MeasureElementLocation(measureIndex: measureIndex, elementIndex: index))
                }
            }
        }
        return members
    }

    /// The tuplets the copy carries, as absolute tick bounds. A tuplet the copied elements never reach is left
    /// alone; one they reach through only SOME of its members is not something a copy can state — MuseScore
    /// refuses the whole operation rather than drop the bracket (`Selection::canCopy`, `select.cpp:1394-1465`),
    /// so this throws `.insideTuplet` naming whichever of the range's two bounds is the one that landed inside
    /// the tuplet, rather than silently keeping only the spans whose first and last member both survived.
    ///
    /// `ids` is a contiguous, onset-ordered slice of the voice per measure (that is what `voiceElements(in:)`
    /// selects), so within one measure a tuplet's first member is missing only when the covered slice starts
    /// after it (the range's earlier bound, `lowBound`), and its last member is missing only when the slice ends
    /// before it (the range's later bound, `highBound`) — there is no other way for `ids` to touch some of a
    /// tuplet's members without touching its first or last.
    static func tupletBounds(
        for ids: [VoiceElementID], staff: StaffAddress, voiceIndex: Int,
        lowBound: VoiceElementID, highBound: VoiceElementID,
        infoByLocation: [MeasureElementLocation: (tick: Int, length: Int)], score: Score,
    ) throws -> [(startTick: Int, endTick: Int, normalNotes: Int, actualNotes: Int)] {
        var measureOrder: [Int] = []
        for id in ids where !measureOrder.contains(id.measureIndex) {
            measureOrder.append(id.measureIndex)
        }

        var tuplets: [(startTick: Int, endTick: Int, normalNotes: Int, actualNotes: Int)] = []
        for measureIndex in measureOrder {
            let ref = VoiceRef(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
            guard let voice = score[voice: ref] else { continue }
            let presentIndices = Set(ids.filter { $0.measureIndex == measureIndex }.map(\.elementIndex))
            for span in voice.tupletSpans {
                guard !presentIndices.isDisjoint(with: span.startIndex ... span.endIndex) else { continue }
                let startPresent = presentIndices.contains(span.startIndex)
                let endPresent = presentIndices.contains(span.endIndex)
                guard startPresent, endPresent else {
                    throw Self.refused(.insideTuplet(at: startPresent ? highBound : lowBound))
                }
                let startLocation = MeasureElementLocation(measureIndex: measureIndex, elementIndex: span.startIndex)
                let endLocation = MeasureElementLocation(measureIndex: measureIndex, elementIndex: span.endIndex)
                guard let start = infoByLocation[startLocation], let end = infoByLocation[endLocation]
                else { continue }
                tuplets.append((
                    startTick: start.tick, endTick: end.tick + end.length,
                    normalNotes: span.normalNotes, actualNotes: span.actualNotes,
                ))
            }
        }
        return tuplets
    }
}
