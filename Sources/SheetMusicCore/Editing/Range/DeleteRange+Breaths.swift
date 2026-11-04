import SheetMusicFoundation

/// The breaths a range delete takes with the slots it deletes (`DeleteRange`'s breath paragraph).
extension DeleteRange {
    /// The breaths the range takes, per bar-voice: every breath whose owner — the chord or rest it follows, looking
    /// back through breaths only, as `SetBreath` and the layout name it — the range covers. For the slot ending its
    /// bar, that includes the breaths at the head of the same voice in the next bar (`Voice.barHeadBreathIndices`),
    /// whether or not the range reaches that bar.
    static func ownedBreaths(
        of groups: [(ref: VoiceRef, covered: Set<Int>)], in score: Score,
    ) -> [VoiceRef: Set<Int>] {
        var result: [VoiceRef: Set<Int>] = [:]
        for (ref, covered) in groups {
            guard let voice = score[voice: ref] else { continue }
            var owner: Int?
            for (index, element) in voice.elements.values.enumerated() {
                switch element {
                case .chord:
                    owner = index
                case .breath:
                    if let owner, covered.contains(owner) { result[ref, default: []].insert(index) }
                default:
                    owner = nil
                }
            }
            guard let last = voice.barEndBreathOwnerIndex, covered.contains(last) else { continue }
            let next = VoiceRef(staff: ref.staff, measureIndex: ref.measureIndex + 1, voiceIndex: ref.voiceIndex)
            guard let heads = score[voice: next]?.barHeadBreathIndices, !heads.isEmpty else { continue }
            result[next, default: []].formUnion(heads)
        }
        return result
    }

    /// Removes the breaths at the head of a bar the range never reached that followed the slot the range covered at
    /// the end of the bar before, appending one command per breath. Those bar-voices are untouched by the rewrite
    /// passes, so `breaths`' indices still hold in `score`.
    ///
    /// Returns the first covered slot of the first such bar-voice before them, for a caller whose rewrite passes
    /// wrote nothing to land on — the range's own slots were rests already spelled as they would be.
    static func removeBreathsBeyond(
        _ groups: [(ref: VoiceRef, covered: Set<Int>)], _ breaths: [VoiceRef: Set<Int>],
        in score: inout Score, ids: inout EIDAllocator, into commands: inout [any EditCommand],
    ) throws -> VoiceElementID? {
        let reached = Set(groups.map(\.ref))
        var location: VoiceElementID?
        for (ref, covered) in groups {
            let next = VoiceRef(staff: ref.staff, measureIndex: ref.measureIndex + 1, voiceIndex: ref.voiceIndex)
            guard !reached.contains(next), let heads = breaths[next] else { continue }
            for index in heads.sorted(by: >) {
                guard let removal = AdjacentElementSlot.removing(at: index, in: next, of: score) else { continue }
                _ = try removal.apply(to: &score, ids: &ids)
                commands.append(removal)
            }
            location = location ?? covered.min().map { index in
                VoiceElementID(
                    staff: ref.staff, measureIndex: ref.measureIndex, voiceIndex: ref.voiceIndex, elementIndex: index,
                )
            }
        }
        return location
    }
}
