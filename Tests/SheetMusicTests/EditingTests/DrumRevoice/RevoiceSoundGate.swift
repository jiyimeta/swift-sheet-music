@testable import SheetMusicCore
import SheetMusicMIDI
import Testing

/// The drum voice conversion's invariant (design 2026-10-26 §5, in the form decision D1 gives it): a conversion
/// keeps what plays and where every marking sits. Every difference is recorded as an `Issue` at the caller's line.
///
/// 1. Rendered, track by track: the SET of note-ons `(tick, channel, pitch)` is equal, and so is the multiset of
///    every event that is neither a note-on nor a note-off — only the note-offs of drum hits may move.
/// 2. In the model, the SET of hits `(bar, onset, pitch, note)` on the staff is equal, tie flags left out.
/// 3. A hit that was tied either way or carried a `.single` tremolo keeps its tie flags, its tremolo and its
///    chord's length, since those lengths are audible (§4.4).
/// 4. A hit's velocity-shaping articulations after include all of those before, and are equal unless its chord
///    after holds hits from more than one source chord (D1: articulations are the union on a merge).
/// 5. The multiset of `(bar, tick, annotation)` on the staff is equal.
/// 6. Every other staff is identical.
enum RevoiceSoundGate {
    /// The articulations the renderer scales a note-on's velocity for — the cases
    /// `MidiRenderer.velocityPreset(for:)` answers, which is the source of truth.
    static let velocityShapingKinds: Set<ChordArticulation.Kind> = [
        .accent, .accentStaccato, .tenutoAccent, .marcato, .marcatoStaccato, .marcatoTenuto,
    ]

    static func expectKeepsSound(
        before: Score, after: Score, staff: StaffAddress, sourceLocation: SourceLocation = #_sourceLocation,
    ) throws {
        var problems: [String] = []
        try compareRenderings(before: before, after: after, into: &problems)
        let hitsBefore = HitIndex(score: before, staff: staff)
        let hitsAfter = HitIndex(score: after, staff: staff)
        compareNotes(before: hitsBefore, after: hitsAfter, into: &problems)
        compareAudibleLengthsAndAccents(before: hitsBefore, after: hitsAfter, into: &problems)
        let annotationsBefore = annotations(in: before, staff: staff)
        let annotationsAfter = annotations(in: after, staff: staff)
        problems += difference(annotationsBefore, annotationsAfter).map { "annotation lost: \($0)" }
        problems += difference(annotationsAfter, annotationsBefore).map { "annotation gained: \($0)" }
        compareOtherStaves(before: before, after: after, staff: staff, into: &problems)
        for problem in problems {
            Issue.record(Comment(rawValue: problem), sourceLocation: sourceLocation)
        }
    }

    // MARK: 1. What the renderer plays

    private static func compareRenderings(before: Score, after: Score, into problems: inout [String]) throws {
        let was = try MidiRenderer.render(score: before)
        let now = try MidiRenderer.render(score: after)
        guard was.tracks.count == now.tracks.count else {
            problems.append("track count \(was.tracks.count) became \(now.tracks.count)")
            return
        }
        for (index, (old, new)) in zip(was.tracks, now.tracks).enumerated() {
            let onsBefore = noteOns(old)
            let onsAfter = noteOns(new)
            problems += onsBefore.subtracting(onsAfter).sorted().map { "track \(index): note-on lost at \($0)" }
            problems += onsAfter.subtracting(onsBefore).sorted().map { "track \(index): note-on gained at \($0)" }
            let othersBefore = otherEvents(old)
            let othersAfter = otherEvents(new)
            problems += difference(othersBefore, othersAfter).map { "track \(index): event lost: \($0)" }
            problems += difference(othersAfter, othersBefore).map { "track \(index): event gained: \($0)" }
        }
    }

    private static func noteOns(_ track: MidiTrack) -> Set<String> {
        Set(track.events.compactMap { timed -> String? in
            guard case let .noteOn(channel, pitch, velocity) = timed.event, velocity > 0 else { return nil }
            return "tick \(timed.tick) channel \(channel) pitch \(pitch)"
        })
    }

    /// Every event but the note-ons and note-offs, by tick then text. The end-of-track meta is left out too: the
    /// renderer puts it one tick after the track's last event, so it follows the final note-off, which may move.
    private static func otherEvents(_ track: MidiTrack) -> [String] {
        track.events
            .compactMap { timed -> (tick: Int, text: String)? in
                switch timed.event {
                case .noteOn, .noteOff, .endOfTrack: nil
                default: (tick: timed.tick, text: String(describing: timed.event))
                }
            }
            .sorted { ($0.tick, $0.text) < ($1.tick, $1.text) }
            .map { "tick \($0.tick): \($0.text)" }
    }

    // MARK: 2–4. The notes in the model

    private struct HitKey: Hashable {
        let measure: Int
        let onset: Int
        let pitch: Int
    }

    private struct ChordKey: Hashable {
        let measure: Int
        let voice: Int
        let element: Int
    }

    private struct HitFacts {
        let note: Note
        let chord: Chord
        let chordKey: ChordKey
        /// The chord's resolved length in ticks.
        let length: Int
    }

    /// Every note on one staff by where it plays, and every chord's notes.
    private struct HitIndex {
        var hits: [HitKey: [HitFacts]] = [:]
        var chords: [ChordKey: [HitKey]] = [:]

        init(score: Score, staff: StaffAddress) {
            guard let target = score[staff] else { return }
            let durations = target.measures.effectiveMeasureDurations()
            for (measureIndex, measure) in target.measures.enumerated() {
                let measureDuration = durations[measureIndex]
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    var tick = 0
                    for (elementIndex, element) in voice.elements.values.enumerated() {
                        defer { tick += element.cursorAdvance(division: score.division, in: measureDuration) }
                        guard case let .chord(chord) = element else { continue }
                        let chordKey = ChordKey(measure: measureIndex, voice: voiceIndex, element: elementIndex)
                        let length = chord.duration.resolved(in: measureDuration).ticks(division: score.division)
                        for note in chord.notes {
                            let key = HitKey(measure: measureIndex, onset: tick, pitch: note.pitch)
                            hits[key, default: []].append(
                                HitFacts(note: note, chord: chord, chordKey: chordKey, length: length),
                            )
                            chords[chordKey, default: []].append(key)
                        }
                    }
                }
            }
        }
    }

    private static func describe(_ key: HitKey) -> String {
        "bar \(key.measure) tick \(key.onset) pitch \(key.pitch)"
    }

    private static func compareNotes(before: HitIndex, after: HitIndex, into problems: inout [String]) {
        func notes(_ index: HitIndex) -> Set<String> {
            Set(index.hits.flatMap { key, facts in
                facts.map { fact in
                    var note = fact.note
                    note.tieForward = nil
                    note.tieBack = nil
                    return "\(describe(key)): \(note)"
                }
            })
        }
        let was = notes(before)
        let now = notes(after)
        problems += was.subtracting(now).sorted().map { "hit lost: \($0)" }
        problems += now.subtracting(was).sorted().map { "hit gained: \($0)" }
    }

    private static func compareAudibleLengthsAndAccents(
        before: HitIndex, after: HitIndex, into problems: inout [String],
    ) {
        for (key, sources) in before.hits {
            // A hit that did not land is reported by `compareNotes`.
            guard let landed = after.hits[key]?.first else { continue }
            for source in sources {
                let isAudible = source.note.tieForward != nil || source.note.tieBack != nil
                    || source.chord.tremolo?.span == .single
                if isAudible, source.note.tieForward != landed.note.tieForward
                    || source.note.tieBack != landed.note.tieBack || source.chord.tremolo != landed.chord.tremolo
                    || source.length != landed.length
                {
                    problems.append("\(describe(key)): tie, tremolo or audible length changed")
                }
                let kindsBefore = velocityKinds(source.chord)
                let kindsAfter = velocityKinds(landed.chord)
                if !kindsAfter.isSuperset(of: kindsBefore) {
                    problems.append("\(describe(key)): lost a velocity-shaping articulation")
                } else if kindsAfter != kindsBefore, !isMerged(landed.chordKey, after: after, before: before) {
                    problems.append("\(describe(key)): gained a velocity-shaping articulation without a merge")
                }
            }
        }
    }

    private static func velocityKinds(_ chord: Chord) -> Set<ChordArticulation.Kind> {
        Set(chord.articulations.map(\.kind)).intersection(velocityShapingKinds)
    }

    /// The chord at `chordKey` after the conversion holds hits that came from more than one source chord.
    private static func isMerged(_ chordKey: ChordKey, after: HitIndex, before: HitIndex) -> Bool {
        let keys = after.chords[chordKey] ?? []
        let sources = Set(keys.flatMap { before.hits[$0]?.map(\.chordKey) ?? [] })
        return sources.count > 1
    }

    // MARK: 5–6. Markings and the other staves

    /// Every stream element that is not a chord or rest, with its bar and tick, sorted.
    private static func annotations(in score: Score, staff: StaffAddress) -> [String] {
        guard let target = score[staff] else { return [] }
        let durations = target.measures.effectiveMeasureDurations()
        var result: [String] = []
        for (measureIndex, measure) in target.measures.enumerated() {
            let measureDuration = durations[measureIndex]
            for voice in measure.voices {
                var tick = 0
                for element in voice.elements {
                    defer { tick += element.cursorAdvance(division: score.division, in: measureDuration) }
                    if case .chord = element { continue }
                    result.append("bar \(measureIndex) tick \(tick): \(element)")
                }
            }
        }
        return result.sorted()
    }

    private static func compareOtherStaves(
        before: Score, after: Score, staff: StaffAddress, into problems: inout [String],
    ) {
        let was = before.allStaves.filter { $0.address != staff }
        let now = after.allStaves.filter { $0.address != staff }
        guard was.count == now.count else {
            problems.append("staff count \(before.allStaves.count) became \(after.allStaves.count)")
            return
        }
        for (old, new) in zip(was, now) where old.address != new.address || old.staff != new.staff {
            problems.append("staff \(old.address) changed")
        }
    }

    /// The members of `lhs` that `rhs` does not match one for one — a multiset difference.
    private static func difference(_ lhs: [String], _ rhs: [String]) -> [String] {
        var remaining = rhs.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return lhs.filter { item in
            guard let count = remaining[item], count > 0 else { return true }
            remaining[item] = count - 1
            return false
        }
    }
}
