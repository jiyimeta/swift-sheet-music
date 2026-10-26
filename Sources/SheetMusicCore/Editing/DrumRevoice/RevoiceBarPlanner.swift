import SheetMusicFoundation

/// Why a bar is left exactly as it was (design §4.7): converting it would change what plays, lose a marking, or move
/// one to another tick. The host reports how many bars were left and which is first; the reason is for tests and
/// diagnostics. It is the failure of a voice's layout, which is why it is an `Error`.
enum RevoiceKeepReason: Error, Equatable {
    /// A shape the writer does not take on.
    case unsupported
    /// A chord whose length is heard — a tie, a roll, after-graces — could not keep it (§4.4).
    case audibleLength
    /// Tuplets that cannot be carried or merged member by member (§4.5).
    case tuplets
    /// A chord-level marking that changes how its notes play — a tremolo or an arpeggio — cannot travel (§4.5).
    case markings
    /// A voice-stream annotation would land inside a chord rather than at an onset.
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

    static func plan(_ bar: RevoiceBar, voiceForPitch: [Int: Int], policy: RhythmSpellingPolicy) -> RevoiceBarPlan {
        if bar.isMeasureRepeat { return .untouched }
        let targetCount = targetVoiceCount(voiceForPitch)
        guard isInTargetVoices(bar, voiceForPitch: voiceForPitch) else {
            return rewrite(bar, voiceForPitch: voiceForPitch, policy: policy)
        }
        guard bar.voices.count > targetCount else { return .untouched }
        // All in place, with voices beyond the target's count: a rest-only voice 2 on a one-voice chart, as MusicXML
        // imports often carry. Removing it is the whole rewrite (§4.6).
        guard bar.voices[targetCount...].allSatisfy(holdsOnlyRests) else { return .leftAsWritten(.unsupported) }
        return .rewrite([], voiceCountAfter: targetCount)
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

    /// The voice holds nothing a removal would drop: no element but rests, and each rest bare — equal to a plain
    /// rest of its duration once its `elementProperties` (visibility, color, offset, placement — none a marking) are
    /// set aside. A rest carrying anything else — an articulation, an ornament, a tremolo, an arpeggio, a lyric, a
    /// grace, a chord-anchored spanner, preserved markup — leaves its bar as written rather than losing it with the
    /// voice.
    static func holdsOnlyRests(_ voice: Voice) -> Bool {
        voice.elements.allSatisfy { element in
            guard case let .chord(chord) = element, chord.notes.isEmpty else { return false }
            var bare = Chord(duration: chord.duration, notes: [])
            bare.elementProperties = chord.elementProperties
            return chord == bare
        }
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
    /// written, so the undo holds only what moved. A bar where a chord cannot keep a length that is heard, where a
    /// tuplet cannot be carried or merged member by member, or where a merge would put a hit into a chord that rolls
    /// differently, is left as written instead.
    static func rewrite(
        _ bar: RevoiceBar, voiceForPitch: [Int: Int], policy: RhythmSpellingPolicy,
    ) -> RevoiceBarPlan {
        if let reason = reasonToLeave(bar) { return .leftAsWritten(reason) }
        let sources = SourceIndex(uniqueKeysWithValues: bar.chords.map { ($0.ref, $0) })
        let chordsByVoice = targetChords(of: bar, voiceForPitch: voiceForPitch)
        var writes: [RevoiceVoiceWrite] = []
        for (voiceIndex, chords) in chordsByVoice.enumerated() {
            let units: [RevoiceTupletUnit]
            switch tupletUnits(of: chords, in: bar, sources: sources) {
            case let .success(carried): units = carried
            case let .failure(reason): return .leftAsWritten(reason)
            }
            let laidOut: [RevoiceTimedSlot]
            switch timeline(
                of: chords, units: units, voiceIndex: voiceIndex, in: bar, sources: sources,
                voiceForPitch: voiceForPitch, policy: policy,
            ) {
            case let .success(timed): laidOut = timed
            case let .failure(reason): return .leftAsWritten(reason)
            }
            guard chords.allSatisfy({ rollsAlike($0, sources: sources) }) else { return .leftAsWritten(.markings) }
            let written = voiceWrite(
                laidOut, units: units, voiceIndex: voiceIndex, voiceCount: chordsByVoice.count, in: bar,
                sources: sources,
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
    /// on. The writer carries every note whole, its ties with it, and gives each chord its length, its roll, its
    /// visibility and its stem and beam visibility, and each tuplet its ratio and how it is drawn; a bar whose chords
    /// or rests carry more — a grace, an articulation, a lyric — keeps it by staying as written (§4.7). So does a bar
    /// whose meter cannot be read, whose cursor a location shift moves, whose tuplets nest, whose two-note tremolo
    /// pairs a chord with its neighbor, or whose notes glide or bend.
    static func reasonToLeave(_ bar: RevoiceBar) -> RevoiceKeepReason? {
        guard bar.isMeterReadable else { return .unsupported }
        if bar.annotations.contains(where: movesCursor) { return .unsupported }
        if bar.hasNestedTuplets { return .unsupported }
        if bar.hits.contains(where: { glidesOrBends($0.note) }) { return .unsupported }
        if bar.chords.contains(where: { pairsWithNeighbor($0.chord) }) { return .unsupported }
        if bar.chords.contains(where: { carriesMarkings($0.chord) }) { return .markings }
        return nil
    }

    private static func movesCursor(_ annotation: RevoiceBar.Annotation) -> Bool {
        if case .locationShift = annotation.element { return true }
        return false
    }

    private static func glidesOrBends(_ note: Note) -> Bool {
        note.glissando != nil || note.guitarBend != nil || note.guitarBendBack || note.legacyBend != nil
    }

    /// A two-note tremolo, or a chord written twice its length for one: both read the chord beside it.
    private static func pairsWithNeighbor(_ chord: Chord) -> Bool {
        chord.tremolo?.span == .between || chord.isWrittenDoubled
    }

    /// The chord carries anything beyond what the writer gives a chord: its notes, its length, its roll, its
    /// visibility and its stems. A rest's roll counts — no hit carries it along.
    private static func carriesMarkings(_ chord: Chord) -> Bool {
        var bare = Chord(duration: chord.duration, notes: chord.notes)
        bare.elementProperties = chord.elementProperties
        bare.stemVisible = chord.stemVisible
        bare.beamVisible = chord.beamVisible
        bare.stemDirection = chord.stemDirection
        bare.beamStemDirection = chord.beamStemDirection
        if !chord.notes.isEmpty { bare.tremolo = chord.tremolo }
        return chord != bare
    }

    /// Every source chord of `chord` rolls alike, or none rolls. A split carries the roll to every part, so every
    /// note keeps rolling; a merge that would put a hit into a chord that rolls differently — a plain kick onto a
    /// rolled snare — would change what plays (§4.5).
    private static func rollsAlike(_ chord: RevoiceTargetChord, sources: SourceIndex) -> Bool {
        Set(chord.sources.map { sources[$0]?.chord.tremolo }).count <= 1
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

    /// The voice as `ReplaceVoiceElements` takes it: each timed slot as a chord or a rest, every annotation bound for
    /// this voice before the slot that starts at its tick — after the last slot at the bar's end — in source order,
    /// and each carried tuplet (`units`) over the slots of its members. Nil when such a tick starts no slot of the
    /// voice.
    private static func voiceWrite(
        _ timeline: [RevoiceTimedSlot], units: [RevoiceTupletUnit], voiceIndex: Int, voiceCount: Int,
        in bar: RevoiceBar, sources: SourceIndex,
    ) -> RevoiceVoiceWrite? {
        let annotations = bar.annotations.filter { annotationVoice(of: $0, voiceCount: voiceCount) == voiceIndex }
        let starts = Set(timeline.map(\.onset) + [bar.meter.barTicks])
        guard annotations.allSatisfy({ starts.contains($0.tick) }) else { return nil }
        var slots: [VoiceSlot] = []
        var memberIndices = [[Int]](repeating: [], count: units.count)
        for timed in timeline {
            slots += annotationSlots(annotations, at: timed.onset, voiceIndex: voiceIndex)
            if let unit = timed.tuplet { memberIndices[unit].append(slots.count) }
            slots.append(chordSlot(timed, voiceIndex: voiceIndex, sources: sources))
        }
        slots += annotationSlots(annotations, at: bar.meter.barTicks, voiceIndex: voiceIndex)
        let tuplets = zip(units, memberIndices).compactMap { unit, members -> TupletSlot? in
            guard let first = members.first, let last = members.last else { return nil }
            return unit.slot(first: first, last: last)
        }
        return RevoiceVoiceWrite(voiceIndex: voiceIndex, slots: slots, tupletSlots: tuplets)
    }

    /// The voice an annotation is written into: its own while the result still has it, voice 0 otherwise (§4.5).
    private static func annotationVoice(of annotation: RevoiceBar.Annotation, voiceCount: Int) -> Int {
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

    /// A timed slot as a voice element. A chord's notes keep every note-level property and their identifiers; its
    /// roll, its visibility and its stem and beam visibility come from the source chord of its lowest-voice hit — the
    /// roll is every source chord's (`rollsAlike`). Its stem and beam directions are left to the voice it now sits
    /// in: a direction a one-voice file forced would otherwise fight voice 2.
    private static func chordSlot(_ timed: RevoiceTimedSlot, voiceIndex: Int, sources: SourceIndex) -> VoiceSlot {
        guard let target = timed.chord else {
            return VoiceSlot(identity: .fresh, element: .rest(duration: timed.duration))
        }
        var chord = Chord(duration: timed.duration, notes: ChordNotes(target.hits.map { ($0.noteEID, $0.note) }))
        if let lowest = target.sources.first.flatMap({ sources[$0] }) {
            chord.tremolo = lowest.chord.tremolo
            chord.elementProperties = lowest.chord.elementProperties
            chord.stemVisible = lowest.chord.stemVisible
            chord.beamVisible = lowest.chord.beamVisible
        }
        let slotIdentity = identity(of: target, voiceIndex: voiceIndex, sources: sources)
        return VoiceSlot(identity: slotIdentity, element: .chord(chord))
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
