import SheetMusicFoundation

/// Where everything a rewritten bar carries besides its notes lands (design §4.5): the target voices each source
/// chord's notes go to, the chord each grace chord rides on, the ticks each voice's annotations stand at, and the
/// lengths a target chord must keep for what rides on it.
struct RevoiceLandings {
    /// A target chord's place: its voice and its onset.
    struct Spot: Hashable {
        let voiceIndex: Int
        let onset: Int
    }

    /// A grace chord of the source bar on the target chord it rides on: the one at its source chord's onset in the
    /// voice of its own pitches (`RevoiceBarPlanner.targetVoice(of:in:)`).
    struct Grace {
        let source: RevoiceBar.ChordRef
        let eid: EID
        let grace: GraceChord
        let isAfter: Bool
        let spot: Spot

        /// It sounds in its chord's own time, so it is heard by how long that chord lasts (`MidiRenderer+Grace`): an
        /// after-grace takes the chord's tail, and a before-grace other than an acciaccatura takes its head, delaying
        /// every note of the chord. An acciaccatura takes its time from the chord before.
        var takesItsChordsTime: Bool {
            isAfter || grace.graceType != .acciaccatura
        }

        /// It delays its chord's notes: a before-grace that takes the chord's head.
        var delaysItsChord: Bool {
            !isAfter && takesItsChordsTime
        }
    }

    /// A length a target chord must keep, the value it is written as, and why the bar is left as written when the
    /// chord cannot keep it.
    struct KeptLength {
        let ticks: Int
        let written: NoteDuration
        let reason: RevoiceKeepReason
    }

    /// The target voices each source chord's notes land in, ascending: more than one when it splits.
    let voicesBySource: [RevoiceBar.ChordRef: [Int]]
    /// Every grace chord that found a chord to ride on, in source order.
    let landed: [Grace]
    /// Some grace chord finds no target chord at its onset in its voice.
    let hasStrandedGrace: Bool
    private let annotationTicksByVoice: [Int: [Int]]
    private let keptLengthsBySpot: [Spot: [KeptLength]]

    /// The landings of `bar` rewritten as `chordsByVoice`. A grace that takes its chord's time keeps the chord it
    /// rides on at its source chord's length: as a length that is heard (`.audibleLength`) when that source sends
    /// the chord a note of its own, as a marking that cannot travel (`.markings`) when the chord is another source
    /// chord's. A fermata keeps the chord it lands on at the length of the one it held (`fermataLength`).
    init(bar: RevoiceBar, chordsByVoice: [[RevoiceTargetChord]], voiceForPitch: [Int: Int]) {
        var voices: [RevoiceBar.ChordRef: Set<Int>] = [:]
        for hit in bar.hits {
            voices[hit.source, default: []].insert(RevoiceBarPlanner.targetVoice(ofPitch: hit.pitch, in: voiceForPitch))
        }
        voicesBySource = voices.mapValues { $0.sorted() }
        var hosts: [Spot: RevoiceTargetChord] = [:]
        for (voiceIndex, chords) in chordsByVoice.enumerated() {
            for chord in chords {
                hosts[Spot(voiceIndex: voiceIndex, onset: chord.onset)] = chord
            }
        }
        var landed: [Grace] = []
        var kept: [Spot: [KeptLength]] = [:]
        var isStranded = false
        for source in bar.chords {
            for grace in Self.graces(of: source, voiceForPitch: voiceForPitch) {
                guard let host = hosts[grace.spot] else {
                    isStranded = true
                    continue
                }
                landed.append(grace)
                guard grace.takesItsChordsTime else { continue }
                let reason: RevoiceKeepReason = host.sources.contains(source.ref) ? .audibleLength : .markings
                kept[grace.spot, default: []].append(
                    KeptLength(ticks: source.length, written: source.chord.duration, reason: reason),
                )
            }
        }
        var ticks: [Int: [Int]] = [:]
        for annotation in bar.annotations {
            let voiceIndex = RevoiceBarPlanner.annotationVoice(of: annotation, voiceCount: chordsByVoice.count)
            ticks[voiceIndex, default: []].append(annotation.tick)
            let spot = Spot(voiceIndex: voiceIndex, onset: annotation.tick)
            guard hosts[spot] != nil, let length = Self.fermataLength(of: annotation, in: bar) else { continue }
            kept[spot, default: []].append(length)
        }
        self.landed = landed
        hasStrandedGrace = isStranded
        annotationTicksByVoice = ticks.mapValues { Array(Set($0)).sorted() }
        keptLengthsBySpot = kept
    }

    /// The ticks voice `voiceIndex`'s annotations stand at, ascending.
    func annotationTicks(of voiceIndex: Int) -> [Int] {
        annotationTicksByVoice[voiceIndex] ?? []
    }

    /// The lengths the target chord at `onset` in voice `voiceIndex` must keep for what rides on it.
    func keptLengths(at voiceIndex: Int, onset: Int) -> [KeptLength] {
        keptLengthsBySpot[Spot(voiceIndex: voiceIndex, onset: onset)] ?? []
    }

    /// The grace chords riding on the target chord at `spot`, in source order.
    func graces(at spot: Spot) -> [Grace] {
        landed.filter { $0.spot == spot }
    }

    /// The lowest target voice `source` sends a note to — the voice of its lowest part.
    func lowestVoice(of source: RevoiceBar.ChordRef) -> Int? {
        voicesBySource[source]?.first
    }

    /// `source`'s grace chords, before then after, each bound for the voice of its own pitches.
    private static func graces(of source: RevoiceBar.SourceChord, voiceForPitch: [Int: Int]) -> [Grace] {
        func riding(_ list: IdentifiedArray<GraceChord>, isAfter: Bool) -> [Grace] {
            list.indices.map { index in
                let voiceIndex = RevoiceBarPlanner.targetVoice(of: list[index], in: voiceForPitch)
                return Grace(
                    source: source.ref, eid: list.eid(at: index), grace: list[index], isAfter: isAfter,
                    spot: Spot(voiceIndex: voiceIndex, onset: source.onset),
                )
            }
        }
        return riding(source.chord.graceNotesBefore, isAfter: false)
            + riding(source.chord.graceNotesAfter, isAfter: true)
    }

    /// The length a fermata keeps for the chord it lands on: that of the chord or rest it held in its own voice — the
    /// next one after it, as `Score.fermataHolds()` anchors it — when that starts at the fermata's tick outside every
    /// tuplet. Nil for every other annotation and every other fermata: `keepsFermataHolds` judges what is left.
    private static func fermataLength(of annotation: RevoiceBar.Annotation, in bar: RevoiceBar) -> KeptLength? {
        guard case .fermata = annotation.element else { return nil }
        let held = bar.chords.first { chord in
            chord.ref.voiceIndex == annotation.voiceIndex && chord.ref.elementIndex > annotation.elementIndex
        }
        guard let held, held.onset == annotation.tick, held.tuplet == nil else { return nil }
        return KeptLength(ticks: held.length, written: held.chord.duration, reason: .annotationPlacement)
    }
}

// MARK: - Chord markings (design §4.5)

extension RevoiceBarPlanner {
    /// Why the bar's chord markings cannot travel with its notes (design §4.5), nil when they all can. A SPLIT is one
    /// source chord's notes landing in several target chords, a MERGE one target chord holding notes from several
    /// source chords. Articulations always travel: to every part, and as a union (D1). Everything else is checked
    /// here, per source chord (`travelsWhole`) and per target chord (`mergeAgrees`); every grace chord must also find
    /// a chord to ride on.
    static func markingsReason(
        _ chordsByVoice: [[RevoiceTargetChord]], in bar: RevoiceBar, sources: SourceIndex, landings: RevoiceLandings,
    ) -> RevoiceKeepReason? {
        if landings.hasStrandedGrace { return .markings }
        for source in bar.chords where !source.chord.notes.isEmpty {
            guard travelsWhole(source, chordsByVoice: chordsByVoice, landings: landings) else { return .markings }
        }
        for (voiceIndex, chords) in chordsByVoice.enumerated() {
            for chord in chords {
                guard mergeAgrees(chord, voiceIndex: voiceIndex, sources: sources, landings: landings) else {
                    return .markings
                }
            }
        }
        return nil
    }

    /// What one source chord carries can go where its notes go: an arpeggio or a chord bracket does not split; a
    /// chord-anchored spanner (a slur) neither splits nor changes voice; a source chord's graces on one side ride on
    /// one chord, since they are timed one after another; and a grace that delays its chord's notes rides on that
    /// chord whole and alone, so no note of it goes undelayed and no other note is delayed.
    private static func travelsWhole(
        _ source: RevoiceBar.SourceChord, chordsByVoice: [[RevoiceTargetChord]], landings: RevoiceLandings,
    ) -> Bool {
        let voices = landings.voicesBySource[source.ref] ?? []
        let splits = voices.count > 1
        if splits, source.chord.arpeggio != nil || source.chord.bracket != nil { return false }
        if !source.chord.spanners.isEmpty, voices != [source.ref.voiceIndex] { return false }
        let landed = landings.landed.filter { $0.source == source.ref }
        for isAfter in [false, true] where Set(landed.filter { $0.isAfter == isAfter }.map(\.spot)).count > 1 {
            return false
        }
        return landed.filter(\.delaysItsChord).allSatisfy { grace in
            !splits && chordsByVoice[grace.spot.voiceIndex].contains { host in
                host.onset == grace.spot.onset && host.sources == [source.ref]
            }
        }
    }

    /// A target chord holding notes from several source chords can carry all they carry: none has an arpeggio or a
    /// chord bracket, all roll alike and share their ornaments (none counts as alike), and at most one carries a
    /// chord-anchored spanner. Whatever the chord holds, at most one source chord whose lowest part it is brings
    /// lyrics, and at most one source chord's graces ride on each side of it.
    private static func mergeAgrees(
        _ chord: RevoiceTargetChord, voiceIndex: Int, sources: SourceIndex, landings: RevoiceLandings,
    ) -> Bool {
        let carried = chord.sources.compactMap { sources[$0]?.chord }
        if carried.count > 1 {
            if carried.contains(where: { $0.arpeggio != nil || $0.bracket != nil }) { return false }
            guard let first = carried.first,
                  carried.allSatisfy({ $0.tremolo == first.tremolo && $0.ornaments == first.ornaments })
            else { return false }
            if carried.count(where: { !$0.spanners.isEmpty }) > 1 { return false }
        }
        let lyricists = chord.sources.count(where: { source in
            landings.lowestVoice(of: source) == voiceIndex && sources[source]?.chord.lyrics.isEmpty == false
        })
        if lyricists > 1 { return false }
        let riders = landings.graces(at: RevoiceLandings.Spot(voiceIndex: voiceIndex, onset: chord.onset))
        return [false, true].allSatisfy { isAfter in
            Set(riders.filter { $0.isAfter == isAfter }.map(\.source)).count <= 1
        }
    }

    /// A timed slot as a voice element (design §4.5, D3). A chord's notes keep every note-level property and their
    /// identifiers. The first of the source chords that sent it notes — the chord of its lowest-voice note — gives
    /// its roll, ornaments, arpeggio, bracket, visibility and stem and beam visibility, which a merge shares
    /// (`markingsReason`). Its articulations are all of theirs in source order, each kind once (D1). A source chord
    /// whose lowest part this is adds its preserved markup, its lyrics and its chord lines written on the chord; a
    /// line written on one note goes with that note (`chordLines`). A chord-anchored spanner rides on the chord its
    /// source carries whole. Its graces are those that ride on it. Its stem and beam directions are left to the voice
    /// it now sits in: a direction a one-voice file forced would otherwise fight voice 2.
    static func chordSlot(
        _ timed: RevoiceTimedSlot, voiceIndex: Int, sources: SourceIndex, landings: RevoiceLandings,
    ) -> VoiceSlot {
        guard let target = timed.chord else {
            return VoiceSlot(identity: .fresh, element: .rest(duration: timed.duration))
        }
        let slotIdentity = identity(of: target, voiceIndex: voiceIndex, sources: sources)
        let carried = target.sources.compactMap { sources[$0] }
        var chord = Chord(duration: timed.duration, notes: ChordNotes(target.hits.map { ($0.noteEID, $0.note) }))
        if let lowest = carried.first?.chord {
            chord.tremolo = lowest.tremolo
            chord.ornaments = lowest.ornaments
            chord.arpeggio = lowest.arpeggio
            chord.bracket = lowest.bracket
            chord.elementProperties = lowest.elementProperties
            chord.stemVisible = lowest.stemVisible
            chord.beamVisible = lowest.beamVisible
        }
        for source in carried {
            for articulation in source.chord.articulations
                where !chord.articulations.contains(where: { $0.kind == articulation.kind })
            {
                chord.articulations.append(articulation)
            }
            let isLowestPart = landings.lowestVoice(of: source.ref) == voiceIndex
            chord.chordLines += chordLines(of: source, on: target, isLowestPart: isLowestPart)
            if isLowestPart {
                chord.preservedMarkup += source.chord.preservedMarkup
                if chord.lyrics.isEmpty { chord.lyrics = source.chord.lyrics }
            }
            if chord.spanners.isEmpty { chord.spanners = source.chord.spanners }
        }
        let keptSource = slotIdentity == .fresh ? nil : target.sources.first
        let riders = landings.graces(at: RevoiceLandings.Spot(voiceIndex: voiceIndex, onset: target.onset))
        chord.graceNotesBefore = graceChords(riders.filter { !$0.isAfter }, keepingIdentifiersOf: keptSource)
        chord.graceNotesAfter = graceChords(riders.filter(\.isAfter), keepingIdentifiersOf: keptSource)
        return VoiceSlot(identity: slotIdentity, element: .chord(chord))
    }

    /// The chord lines `source` hands the chord built from `target`: one written on the chord when this is the
    /// source's lowest part, one written on a note when that note is here, its index renumbered for the notes it now
    /// sits among. A note index the source chord does not have counts as written on the chord.
    private static func chordLines(
        of source: RevoiceBar.SourceChord, on target: RevoiceTargetChord, isLowestPart: Bool,
    ) -> [ChordLine] {
        source.chord.chordLines.compactMap { line in
            guard let noteIndex = line.noteIndex, source.chord.notes.indices.contains(noteIndex) else {
                return isLowestPart ? line : nil
            }
            let pitch = source.chord.notes[noteIndex].pitch
            guard let index = target.hits.firstIndex(where: { $0.pitch == pitch }) else { return nil }
            var moved = line
            moved.noteIndex = index
            return moved
        }
    }

    /// The grace chords riding on one side of a chord, in source order. A grace keeps its identifier only on the
    /// chord its own source chord is kept as (D8); anywhere else it is a new grace, given identifiers as it lands.
    private static func graceChords(
        _ riders: [RevoiceLandings.Grace], keepingIdentifiersOf keptSource: RevoiceBar.ChordRef?,
    ) -> IdentifiedArray<GraceChord> {
        IdentifiedArray(riders.map { ($0.source == keptSource ? $0.eid : .invalid, $0.grace) })
    }

    /// A source chord carried whole into its own voice index — no hit split away, nothing merged in — keeps its
    /// identifier, and its notes theirs. A chord that moved, split or merged is fresh, so no identifier is held by
    /// two voices partway through the bar's commands, which write one voice at a time.
    private static func identity(
        of target: RevoiceTargetChord, voiceIndex: Int, sources: SourceIndex,
    ) -> SlotIdentity {
        guard target.sources.count == 1, let ref = target.sources.first, ref.voiceIndex == voiceIndex,
              let source = sources[ref], source.chord.notes.count == target.hits.count
        else { return .fresh }
        return .keep(source.eid)
    }
}

// MARK: - Annotations (design §4.5, §4.6)

extension RevoiceBarPlanner {
    /// Voice 0 of a bar whose notes all sit in place, with `moved` — the annotations of the voices beyond the target's
    /// count — inserted at their ticks after voice 0's own, in source order: each before the chord or rest of voice 0
    /// that starts there, or after its last element at the tick voice 0 ends. Every element and tuplet of voice 0
    /// keeps its identifier and its value — nothing is re-spelled (§4.6) — and a tuplet spans the same members. Nil
    /// when such a tick starts no element of voice 0, or a tuplet of it names no member.
    static func insertingAnnotations(_ moved: [RevoiceBar.Annotation], into bar: RevoiceBar) -> RevoiceVoiceWrite? {
        let voice = bar.voices[0]
        let elements = bar.chords.filter { $0.ref.voiceIndex == 0 }
        let end = elements.map { $0.onset + $0.length }.max() ?? 0
        var inserted: [Int: [VoiceSlot]] = [:]
        for annotation in moved {
            let position: Int
            if let start = elements.first(where: { $0.onset == annotation.tick }) {
                position = start.ref.elementIndex
            } else if annotation.tick == end {
                position = voice.elements.count
            } else {
                return nil
            }
            inserted[position, default: []].append(VoiceSlot(identity: .fresh, element: annotation.element))
        }
        var slots: [VoiceSlot] = []
        var positions: [Int] = []
        for index in voice.elements.indices {
            slots += inserted[index] ?? []
            positions.append(slots.count)
            slots.append(VoiceSlot(identity: .keep(voice.elements.eid(at: index)), element: voice.elements[index]))
        }
        slots += inserted[voice.elements.count] ?? []
        let spans = voice.tupletSpans
        guard spans.allSatisfy({ $0.isResolved && $0.endIndex < positions.count }) else { return nil }
        let tuplets = spans.map { span in
            TupletSlot(identity: .keep(span.eid), tuplet: Tuplet(
                normalNotes: span.normalNotes, actualNotes: span.actualNotes, startIndex: positions[span.startIndex],
                endIndex: positions[span.endIndex], appearance: span.appearance,
            ))
        }
        return RevoiceVoiceWrite(voiceIndex: 0, slots: slots, tupletSlots: tuplets)
    }

    /// Every fermata of the bar still holds a chord or rest of the length it held (`Score.fermataHolds()`): how long a
    /// hold lasts is heard, as the tempo it stretches. The bar after the rewrite is its writes, and its other voices
    /// below `voiceCountAfter` as they are.
    static func keepsFermataHolds(_ bar: RevoiceBar, writes: [RevoiceVoiceWrite], voiceCountAfter: Int) -> Bool {
        guard bar.annotations.contains(where: isFermata) else { return true }
        let after = (0 ..< voiceCountAfter).compactMap { voiceIndex -> Voice? in
            if let write = writes.first(where: { $0.voiceIndex == voiceIndex }) { return write.voice }
            return bar.voices.indices.contains(voiceIndex) ? bar.voices[voiceIndex] : nil
        }
        return fermataHolds(of: bar.voices, in: bar) == fermataHolds(of: after, in: bar)
    }

    private static func isFermata(_ annotation: RevoiceBar.Annotation) -> Bool {
        if case .fermata = annotation.element { return true }
        return false
    }

    /// The holds `voices` give the bar's fermatas, in a stable order.
    private static func fermataHolds(of voices: [Voice], in bar: RevoiceBar) -> [FermataHold] {
        let division = bar.meter.division
        let measure = Fraction(ticks: bar.meter.barTicks, division: division)
        let holds = voices.flatMap { voice in
            Score.holds(in: voice, measureIndex: bar.measureIndex, measureDuration: measure, division: division)
        }
        return holds.sorted {
            ($0.startTickInMeasure, $0.ticks, $0.stretch) < ($1.startTickInMeasure, $1.ticks, $1.stretch)
        }
    }
}
