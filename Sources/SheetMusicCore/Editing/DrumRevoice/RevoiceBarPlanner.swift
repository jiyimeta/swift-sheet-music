import SheetMusicFoundation

/// Why a bar is left exactly as it was (design §4.7): converting it would change what plays, lose a marking, or move
/// one to another tick. The host reports how many bars were left and which is first; the reason is for tests and
/// diagnostics. It is the failure of a voice's layout, which is why it is an `Error`.
enum RevoiceKeepReason: Error, Equatable {
    /// A shape the writer does not take on.
    case unsupported
    /// A chord whose length is heard — a tie, a roll, an arpeggio, graces that sound in its time — could not keep it
    /// (§4.4).
    case audibleLength
    /// Tuplets that cannot be carried or merged member by member (§4.5).
    case tuplets
    /// A chord or rest marking cannot travel with its notes (§4.5): a roll or an arpeggio a split or merge would
    /// change, a grace with no chord to ride on or one its new chord cannot time as before, ornaments or lyrics two
    /// merging chords do not share, a slur on a chord that splits or changes voice, any marking on a rest.
    case markings
    /// A voice-stream annotation would land inside a chord rather than at an onset, or a fermata would hold a chord
    /// of another length.
    case annotationPlacement
    /// A dynamic or hairpin assigned to its own voice only would govern other notes (§4.5).
    case voiceOnlyDynamics
    /// The meter cannot spell what the bar needs.
    case unspellable
}

/// What a rewritten bar writes into one voice: the whole voice, as `ReplaceVoiceElements` takes it.
struct RevoiceVoiceWrite: Equatable, Sendable {
    let voiceIndex: Int
    let slots: [VoiceSlot]
    let tupletSlots: [TupletSlot]

    /// The voice this write leaves, identifiers aside: what `Voice`'s content equality compares — the elements, and
    /// each tuplet's ratio, members and appearance.
    var voice: Voice {
        Voice(elements: slots.map(\.element), tuplets: tupletSlots.map(\.tuplet))
    }
}

/// The decision for one bar.
enum RevoiceBarPlan: Equatable, Sendable {
    /// Already in the target form (design §4.6), or a measure repeat: not touched at all, not even re-spelled.
    case untouched
    /// Converting it would break one of the design's anti-goals; it stays as it was (§4.7).
    case leftAsWritten(RevoiceKeepReason)
    /// Write these voices, then leave the bar with `voiceCountAfter` voices — creating the ones a write targets that
    /// the bar does not have yet, and removing every voice from the last down to that count. The list of writes may
    /// be empty (`.rewrite([], voiceCountAfter:)` only removes voices), but the effect never is: a bar that would
    /// change nothing is `.untouched`.
    case rewrite([RevoiceVoiceWrite], voiceCountAfter: Int)
}

/// Decides, per bar, whether `RevoiceDrumStaff` leaves it alone, leaves it as written, or rewrites it, and writes the
/// voices of a rewritten one.
enum RevoiceBarPlanner {
    /// The bar's chords and rests by where they sit.
    typealias SourceIndex = [RevoiceBar.ChordRef: RevoiceBar.SourceChord]

    /// A rewrite that would change how long a fermata holds is left as written instead: the hold is heard, as the
    /// tempo it stretches (`keepsFermataHolds`).
    static func plan(_ bar: RevoiceBar, voiceForPitch: [Int: Int], policy: RhythmSpellingPolicy) -> RevoiceBarPlan {
        if bar.isMeasureRepeat { return .untouched }
        let planned = isInTargetVoices(bar, voiceForPitch: voiceForPitch)
            ? removingVoices(bar, voiceForPitch: voiceForPitch, policy: policy)
            : rewrite(bar, voiceForPitch: voiceForPitch, policy: policy)
        if case let .rewrite(writes, voiceCountAfter) = planned,
           !keepsFermataHolds(bar, writes: writes, voiceCountAfter: voiceCountAfter)
        {
            return .leftAsWritten(.annotationPlacement)
        }
        return planned
    }

    /// A bar whose notes all sit in their target voices (§4.6): untouched unless it has voices beyond the target's
    /// count. Those go when they hold nothing but bare rests and annotations — a rest-only voice 2 on a one-voice
    /// chart, as MusicXML imports often carry — and their annotations move to voice 0 at their ticks (§4.5). Voice 0
    /// keeps every element it has when each such tick starts one of them; otherwise it is written afresh, cut there.
    private static func removingVoices(
        _ bar: RevoiceBar, voiceForPitch: [Int: Int], policy: RhythmSpellingPolicy,
    ) -> RevoiceBarPlan {
        let targetCount = targetVoiceCount(voiceForPitch)
        guard bar.voices.count > targetCount else { return .untouched }
        let extra = bar.voices[targetCount...].flatMap(\.elements.values)
        let moved = bar.annotations.filter { $0.voiceIndex >= targetCount }
        guard extra.allSatisfy({ isBareRest($0) || !isChord($0) }),
              !moved.contains(where: { movesPlayback($0, in: bar) })
        else { return .leftAsWritten(.unsupported) }
        guard !moved.isEmpty else { return .rewrite([], voiceCountAfter: targetCount) }
        guard let write = insertingAnnotations(moved, into: bar) else {
            return rewrite(bar, voiceForPitch: voiceForPitch, policy: policy)
        }
        return .rewrite([write], voiceCountAfter: targetCount)
    }

    /// How many voices the target form has: one more than the highest voice the mapping names, at least one.
    static func targetVoiceCount(_ voiceForPitch: [Int: Int]) -> Int {
        max(1, (voiceForPitch.values.max() ?? 0) + 1)
    }

    /// The voice a note of `pitch` belongs in. A pitch the mapping does not name goes to voice 0 (design §7).
    static func targetVoice(ofPitch pitch: Int, in voiceForPitch: [Int: Int]) -> Int {
        voiceForPitch[pitch] ?? 0
    }

    /// The voice a grace chord belongs in: the one its notes share, or voice 0 when they map to different voices —
    /// a flam on the snare stays with the snare (design §4.5).
    static func targetVoice(of grace: GraceChord, in voiceForPitch: [Int: Int]) -> Int {
        let voices = Set(grace.notes.map { targetVoice(ofPitch: $0.pitch, in: voiceForPitch) })
        guard voices.count == 1, let only = voices.first else { return 0 }
        return only
    }

    /// Every note of the bar sits in its target voice (design §4.6), grace notes included: each grace chord belongs
    /// in the voice of the chord that carries it.
    static func isInTargetVoices(_ bar: RevoiceBar, voiceForPitch: [Int: Int]) -> Bool {
        let notesInPlace = bar.hits.allSatisfy { hit in
            targetVoice(ofPitch: hit.pitch, in: voiceForPitch) == hit.source.voiceIndex
        }
        return notesInPlace && bar.chords.allSatisfy { source in
            (source.chord.graceNotesBefore.values + source.chord.graceNotesAfter.values).allSatisfy { grace in
                targetVoice(of: grace, in: voiceForPitch) == source.ref.voiceIndex
            }
        }
    }

    /// A rest that holds nothing a removal would drop: equal to a plain rest of its duration once its
    /// `elementProperties` (visibility, color, offset, placement — none a marking) are set aside.
    static func isBareRest(_ element: VoiceElement) -> Bool {
        guard case let .chord(rest) = element, rest.notes.isEmpty else { return false }
        var bare = Chord(duration: rest.duration, notes: [])
        bare.elementProperties = rest.elementProperties
        return rest == bare
    }

    private static func isChord(_ element: VoiceElement) -> Bool {
        if case .chord = element { return true }
        return false
    }
}

// MARK: - Writing a bar from its hits (design §4.1–§4.3)

/// One chord of a rewritten voice: every hit bound for that voice at one onset (design §4.1).
struct RevoiceTargetChord {
    let onset: Int
    /// One hit per pitch, ascending. Of two hits of one pitch — two source voices sounding the same drum at once —
    /// the one from the lower source voice is kept.
    let hits: [RevoiceBar.Hit]
    /// Every hit bound here, a dropped duplicate included, in source order.
    let incoming: [RevoiceBar.Hit]
    /// Every source chord that sent a hit here, in source order, the one whose duplicate was dropped included: the
    /// first is the chord of the lowest-voice hit.
    let sources: [RevoiceBar.ChordRef]

    /// `hits` in source order, voice by voice, as `RevoiceBar.hits` lists them.
    init(onset: Int, hits: [RevoiceBar.Hit]) {
        self.onset = onset
        incoming = hits
        var pitches = Set<Int>()
        self.hits = hits.filter { pitches.insert($0.pitch).inserted }.sorted { $0.pitch < $1.pitch }
        var sources: [RevoiceBar.ChordRef] = []
        for hit in hits where !sources.contains(hit.source) {
            sources.append(hit.source)
        }
        self.sources = sources
    }
}

extension RevoiceBarPlanner {
    /// A bar not in the target form, written afresh from its hits (design §4.1–§4.5). Every voice up to the highest
    /// one a hit lands in is written — one that no hit reaches as rests, so the bar's voices stay contiguous — and
    /// every voice above it is removed. A voice whose rewrite reads exactly as it does now, tuplets included, is not
    /// written, so the undo holds only what moved.
    ///
    /// Every voice is laid out before any marking is judged, so a length that cannot be kept (`.audibleLength`) or a
    /// tuplet that cannot be carried (`.tuplets`) is the reason a bar reports even when a marking could not travel
    /// either; an annotation that starts no slot of its voice (`.annotationPlacement`) is judged last.
    static func rewrite(
        _ bar: RevoiceBar, voiceForPitch: [Int: Int], policy: RhythmSpellingPolicy,
    ) -> RevoiceBarPlan {
        if let reason = reasonToLeave(bar) { return .leftAsWritten(reason) }
        let sources = SourceIndex(uniqueKeysWithValues: bar.chords.map { ($0.ref, $0) })
        let chordsByVoice = targetChords(of: bar, voiceForPitch: voiceForPitch)
        let landings = RevoiceLandings(bar: bar, chordsByVoice: chordsByVoice, voiceForPitch: voiceForPitch)
        var laidOut: [(units: [RevoiceTupletUnit], timeline: [RevoiceTimedSlot])] = []
        for (voiceIndex, chords) in chordsByVoice.enumerated() {
            let laidOutVoice = tupletUnits(of: chords, in: bar, sources: sources).flatMap { units in
                timeline(
                    of: chords, units: units, voiceIndex: voiceIndex, in: bar, sources: sources, landings: landings,
                    policy: policy,
                ).map { (units: units, timeline: $0) }
            }
            switch laidOutVoice {
            case let .success(voice): laidOut.append(voice)
            case let .failure(reason): return .leftAsWritten(reason)
            }
        }
        if let reason = markingsReason(chordsByVoice, in: bar, sources: sources, landings: landings) {
            return .leftAsWritten(reason)
        }
        var writes: [RevoiceVoiceWrite] = []
        for (voiceIndex, voice) in laidOut.enumerated() {
            let written = voiceWrite(
                voice.timeline, units: voice.units, voiceIndex: voiceIndex, voiceCount: chordsByVoice.count, in: bar,
                sources: sources, landings: landings,
            )
            guard let write = written else { return .leftAsWritten(.annotationPlacement) }
            let isUnchanged = bar.voices.indices.contains(voiceIndex) && write.voice == bar.voices[voiceIndex]
            guard !isUnchanged else { continue }
            writes.append(write)
        }
        guard !writes.isEmpty || chordsByVoice.count < bar.voices.count else { return .untouched }
        return .rewrite(writes, voiceCountAfter: chordsByVoice.count)
    }

    /// Why a bar not in the target form is left as written before anything is written, nil when the writer takes it
    /// on: a meter that cannot be read, an element that moves its voice's playback (`movesPlayback`), nested
    /// tuplets, a two-note tremolo that pairs a chord with its neighbor, notes that glide or bend, or a rest carrying
    /// a marking — rests are spelled afresh, so nothing a rest carries could travel.
    static func reasonToLeave(_ bar: RevoiceBar) -> RevoiceKeepReason? {
        guard bar.isMeterReadable else { return .unsupported }
        if bar.annotations.contains(where: { movesPlayback($0, in: bar) }) { return .unsupported }
        if bar.hasNestedTuplets { return .unsupported }
        if bar.hits.contains(where: { glidesOrBends($0.note) }) { return .unsupported }
        if bar.chords.contains(where: { pairsWithNeighbor($0.chord) }) { return .unsupported }
        if bar.chords.contains(where: { $0.chord.notes.isEmpty && carriesMarkings($0.chord) }) { return .markings }
        return nil
    }

    /// A location shift moves its voice's cursor; a breath's pause delays every later note of its voice
    /// (`MidiRenderer`'s voice walk), so a bar whose notes change voice around one would play differently. A pause at
    /// the bar's end delays nothing.
    static func movesPlayback(_ annotation: RevoiceBar.Annotation, in bar: RevoiceBar) -> Bool {
        switch annotation.element {
        case .locationShift: true
        case let .breath(breath): breath.pause > 0 && annotation.tick < bar.meter.barTicks
        default: false
        }
    }

    private static func glidesOrBends(_ note: Note) -> Bool {
        note.glissando != nil || note.guitarBend != nil || note.guitarBendBack || note.legacyBend != nil
    }

    /// A two-note tremolo, or a chord written twice its length for one: both read the chord beside it.
    private static func pairsWithNeighbor(_ chord: Chord) -> Bool {
        chord.tremolo?.span == .between || chord.isWrittenDoubled
    }

    /// The rest carries anything beyond its length, its visibility and its stems — a roll included, since no hit
    /// carries it along.
    private static func carriesMarkings(_ rest: Chord) -> Bool {
        var bare = Chord(duration: rest.duration, notes: rest.notes)
        bare.elementProperties = rest.elementProperties
        bare.stemVisible = rest.stemVisible
        bare.beamVisible = rest.beamVisible
        bare.stemDirection = rest.stemDirection
        bare.beamStemDirection = rest.beamStemDirection
        return rest != bare
    }

    /// The bar's hits gathered into the chords each target voice is written with: one list per voice up to the highest
    /// one a hit lands in — voice 0 at least, an empty list for a voice no hit reaches — each in onset order.
    static func targetChords(of bar: RevoiceBar, voiceForPitch: [Int: Int]) -> [[RevoiceTargetChord]] {
        var hitsByVoice: [Int: [Int: [RevoiceBar.Hit]]] = [:]
        for hit in bar.hits {
            let voiceIndex = targetVoice(ofPitch: hit.pitch, in: voiceForPitch)
            hitsByVoice[voiceIndex, default: [:]][hit.onset, default: []].append(hit)
        }
        let voiceCount = max(1, (hitsByVoice.keys.max() ?? 0) + 1)
        return (0 ..< voiceCount).map { voiceIndex in
            (hitsByVoice[voiceIndex] ?? [:])
                .sorted { $0.key < $1.key }
                .map { RevoiceTargetChord(onset: $0.key, hits: $0.value) }
        }
    }

    // MARK: Slots

    /// The voice as `ReplaceVoiceElements` takes it: each timed slot as a chord or a rest (`chordSlot`), every
    /// annotation bound for this voice before the slot that starts at its tick — after the last slot at the bar's end
    /// — in source order, and each carried tuplet (`units`) over the slots of its members. Nil when such a tick starts
    /// no slot of the voice: it falls inside a chord whose length is kept, or inside a tuplet member.
    private static func voiceWrite(
        _ timeline: [RevoiceTimedSlot], units: [RevoiceTupletUnit], voiceIndex: Int, voiceCount: Int,
        in bar: RevoiceBar, sources: SourceIndex, landings: RevoiceLandings,
    ) -> RevoiceVoiceWrite? {
        let annotations = bar.annotations.filter { annotationVoice(of: $0, voiceCount: voiceCount) == voiceIndex }
        let starts = Set(timeline.map(\.onset) + [bar.meter.barTicks])
        guard annotations.allSatisfy({ starts.contains($0.tick) }) else { return nil }
        var slots: [VoiceSlot] = []
        var memberIndices = [[Int]](repeating: [], count: units.count)
        for timed in timeline {
            slots += annotationSlots(annotations, at: timed.onset, voiceIndex: voiceIndex)
            if let unit = timed.tuplet { memberIndices[unit].append(slots.count) }
            slots.append(chordSlot(timed, voiceIndex: voiceIndex, sources: sources, landings: landings))
        }
        slots += annotationSlots(annotations, at: bar.meter.barTicks, voiceIndex: voiceIndex)
        let tuplets = zip(units, memberIndices).compactMap { unit, members -> TupletSlot? in
            guard let first = members.first, let last = members.last else { return nil }
            return unit.slot(first: first, last: last)
        }
        return RevoiceVoiceWrite(voiceIndex: voiceIndex, slots: slots, tupletSlots: tuplets)
    }

    /// The voice an annotation is written into: its own while the result still has it, voice 0 otherwise (§4.5).
    static func annotationVoice(of annotation: RevoiceBar.Annotation, voiceCount: Int) -> Int {
        annotation.voiceIndex < voiceCount ? annotation.voiceIndex : 0
    }

    /// The annotations at `tick`, in source order. One staying in its own voice keeps its identifier.
    private static func annotationSlots(
        _ annotations: [RevoiceBar.Annotation], at tick: Int, voiceIndex: Int,
    ) -> [VoiceSlot] {
        annotations.filter { $0.tick == tick }.map { annotation in
            let slotIdentity: SlotIdentity = annotation.voiceIndex == voiceIndex ? .keep(annotation.eid) : .fresh
            return VoiceSlot(identity: slotIdentity, element: annotation.element)
        }
    }
}
