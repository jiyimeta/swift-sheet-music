import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// Per-voice-element bend-chain playback state, computed in a pre-pass
    /// before the voice walk. Keyed by `elementIndex` within the voice.
    ///
    /// A guitar bend is not a second attack: the string keeps ringing and the
    /// player pushes it up, so a whole chain of notated pitches sounds as ONE
    /// MIDI key with the pitch wheel doing the work. Each chord in the chain
    /// gets one slot describing where the wheel already is when the chord
    /// starts and where it has to be by the time the chord ends.
    struct BendChainSlot: Equatable {
        /// MIDI key that actually sounds for this chord's bend chain
        /// (the chain's first note pitch).
        var basePitch: Int
        /// Wheel offset in quarter tones already applied when this chord starts.
        var startOffsetQuarterTones: Int
        /// Offset to ramp to during this chord (nil = hold; chain end).
        var targetOffsetQuarterTones: Int?
        var isChainStart: Bool
        var isChainEnd: Bool
        /// Time factors of the bend that *starts* on this chord (chain-end
        /// slots have none, and hold across the whole chord).
        var startTimeFactor: Double
        var endTimeFactor: Double
    }

    /// Which grace chord of a voice element a slot belongs to. `nil` (the
    /// absent case in `BendChainChordSlots`) means the principal chord.
    enum BendChainGraceRole: Hashable {
        case before(Int)
        case after(Int)
    }

    /// Every bend-chain slot one voice element owns. A chain runs through
    /// grace notes as freely as through principal chords — MuseScore's
    /// `collectGuitarBend` walks `bendFor()` links without caring whether the
    /// note it lands on is a grace — so one element can host several members
    /// of the same chain (`guitarbend_release_twice`'s second chord carries
    /// two of them in its after-graces).
    struct BendChainChordSlots: Equatable {
        var parent: BendChainSlot?
        var before: [Int: BendChainSlot] = [:]
        var after: [Int: BendChainSlot] = [:]

        mutating func set(_ slot: BendChainSlot, at role: BendChainGraceRole?) {
            switch role {
            case .none: parent = slot
            case let .some(.before(index)): before[index] = slot
            case let .some(.after(index)): after[index] = slot
            }
        }
    }

    /// One place in a voice that can host a chain slot, listed in playback
    /// order: each chord contributes its before-graces, then its principal
    /// notes, then its after-graces.
    private struct ChainPosition {
        var elementIndex: Int
        var grace: BendChainGraceRole?
        /// The chain-carrying note here, or nil when this position cannot take
        /// part in a chain (see `chainPositions`). A position with no note
        /// still occupies a slot in the walk, so a chain can never link past
        /// a chord that would re-articulate between its members.
        var note: Note?
    }

    // MARK: - Chain construction

    /// Bend-chain slots for one voice's elements, keyed by element index.
    ///
    /// Mirrors the chain walk in MuseScore's MIDI compatibility renderer
    /// (`engraving/compat/midi/compatmidirenderinternal.cpp`): the begin note
    /// of a `<Spanner type="GuitarBend">` pair owns the payload, and each
    /// `<prev>`-side note continues the same sounding key rather than striking
    /// a new one.
    ///
    /// Suppression keys off THIS map, never off `Note.guitarBendBack` alone: a
    /// `<prev>`-only spanner survives decoding when its begin side was dropped
    /// (unknown `<guitarBendType>`, missing `<GuitarBend>` payload), and such a
    /// note has to attack normally or it would be silent.
    ///
    /// ## Ties are walked in the same pass
    ///
    /// A tie and a bend make the same claim — the key already sounds, do not
    /// strike it again — so the two suppression rules have to be decided
    /// together or each will re-decide the other's attack and release.
    /// MuseScore composes them in one loop (`collectGuitarBend`:
    /// `while (note->bendFor() || note->tieFor())`, whose `else` branch simply
    /// follows `tieFor()` and holds the wheel where it is), and so does this:
    /// a tied member is a chain interior with no target, and only the chain's
    /// last member releases the key.
    ///
    /// ## What v1 deliberately does not curve
    ///
    /// - `preBend` — MuseScore takes a pre-bend's distance from the tab fret
    ///   data (the parenthesised grace note is the *fretted* pitch, the
    ///   principal is the *bent* one), which this model does not carry, so
    ///   there is no pitch delta to ramp. The note plays straight at its
    ///   written pitch with the wheel untouched.
    /// - The four whammy-bar types (`dive`, `preDive`, `dip`, `scoop`) — their
    ///   depth lives in properties this model announces and drops at decode.
    ///
    /// ## Chord-level simplification
    ///
    /// The pitch wheel is a channel-wide control, so a chord that mixes bent
    /// and unbent notes bends all of them. MuseScore's own MIDI export has the
    /// same limitation; bends are single-note in practice.
    static func guitarBendChains(voiceElements: [VoiceElement]) -> [Int: BendChainChordSlots] {
        let positions = chainPositions(in: voiceElements)
        var slots: [Int: BendChainChordSlots] = [:]
        var index = 0
        while index < positions.count {
            guard let chain = bendChain(positions: positions, startingAt: index) else {
                index += 1
                continue
            }
            for (positionIndex, slot) in chain {
                let position = positions[positionIndex]
                var chordSlots = slots[position.elementIndex] ?? BendChainChordSlots()
                chordSlots.set(slot, at: position.grace)
                slots[position.elementIndex] = chordSlots
            }
            index = (chain.last?.0 ?? index) + 1
        }
        return slots
    }

    /// The note a chord (or grace chord) sounds its bend chain on: the first
    /// note carrying either side of a `<Spanner type="GuitarBend">` pair, and
    /// failing that the first tied note. A chain reaching through a tie has
    /// members carrying no bend spanner at all — `guitarbend_tied` closes on a
    /// plain tied half note, and a chain tied INTO is struck on the plain note
    /// the tie starts from.
    ///
    /// `ChordNotes` is pitch-unique, so the note this returns is exactly the
    /// one `renderChordWithGraces` finds again by pitch. The chord-level
    /// simplification documented on `guitarBendChains` is what makes "first"
    /// good enough. A muted note yields nil: it emits no MIDI, so it can
    /// neither open a chain nor carry one through.
    static func bendChainNote(in notes: ChordNotes) -> Note? {
        let candidate = notes.first { $0.guitarBend != nil || $0.guitarBendBack }
            ?? notes.first { $0.tieBack != nil || $0.tieForward != nil }
        guard let candidate, candidate.play else { return nil }
        return candidate
    }

    /// Every position a chain could pass through, in playback order.
    ///
    /// A position with a nil `note` is a wall: the walk sees it, so a chain can
    /// never link across a chord that would re-articulate in between. Rests
    /// (note-less chords) and non-chord elements produce no position at all —
    /// `.dynamic` / `.locationShift` / `.breath` / the signatures emit no note
    /// events and make `renderVoiceElement` skip nothing, so stepping over them
    /// is safe. In particular there is **no** `.instrumentChange` voice
    /// element: a mid-part channel switch reaches the walker as a tick-keyed
    /// `PartChannelRoute` entry, so refusing chains that step over an element
    /// would not close the "channel switches inside a chain" hazard. That one
    /// needs the chain's channel pinned at its head, the way `sustainedChannel`
    /// pins a tie's.
    ///
    /// A chord whose render path never consults the chain map hosts no note,
    /// because a slot the renderer never reaches would emit a note-off with no
    /// note-on and `resolveUnisonOverlap` would then discard it, silencing the
    /// whole chain instead of merely un-bending it. Two such paths:
    ///
    /// - The chord CARRIES a tremolo or an arpeggio (`renderTremoloChord`
    ///   emits its own strokes and never renders graces; the arpeggio branch
    ///   of `renderChordWithGraces` bypasses the chain-aware note loop).
    /// - The chord is CONSUMED by a preceding `.between` tremolo. Such a chord
    ///   has `tremolo == nil` itself, so the check above cannot see it — the
    ///   voice walker `continue`s past it before `renderVoiceElement` runs.
    ///
    /// The voice walker performs exactly two `continue`s over a chord
    /// (`MidiRenderer+Voice.swift`): the tremolo-consumed follower, and the
    /// tremolo-CARRYING chord that routes to `renderTremoloChord` instead.
    /// The second is already covered by the `chord.tremolo == nil` test above,
    /// so between them the two clauses close the whole "the renderer never
    /// reaches this slot" class. (The walker's other `continue`s skip a whole
    /// measure or a whole voice, above the level of the element array this
    /// walk is handed, so they cannot strand a slot inside it.)
    ///
    /// A note-less chord hosts no position at all, its graces included: the
    /// renderer's grace path hangs off the parent chord's notes, so a grace
    /// slot on a chord with nothing to strike would never be reached either.
    /// The parser cannot build such a chord today, so the guard is structural;
    /// `chainMap_skipsGracesOfANoteLessChord` pins it by handing the walk a
    /// hand-built element array.
    private static func chainPositions(in voiceElements: [VoiceElement]) -> [ChainPosition] {
        let skipped = tremoloConsumedIndices(in: voiceElements)
        var positions: [ChainPosition] = []
        for (elementIndex, element) in voiceElements.enumerated() {
            guard case let .chord(chord) = element, !chord.notes.isEmpty
            else { continue }
            let renderable = !skipped.contains(elementIndex)
                && chord.tremolo == nil && chord.arpeggio == nil
            for (graceIndex, grace) in chord.graceNotesBefore.enumerated()
                where !grace.notes.isEmpty
            {
                positions.append(ChainPosition(
                    elementIndex: elementIndex, grace: .before(graceIndex),
                    note: renderable ? bendChainNote(in: grace.notes) : nil,
                ))
            }
            positions.append(ChainPosition(
                elementIndex: elementIndex, grace: nil,
                note: renderable ? bendChainNote(in: chord.notes) : nil,
            ))
            for (graceIndex, grace) in chord.graceNotesAfter.enumerated()
                where !grace.notes.isEmpty
            {
                positions.append(ChainPosition(
                    elementIndex: elementIndex, grace: .after(graceIndex),
                    note: renderable ? bendChainNote(in: grace.notes) : nil,
                ))
            }
        }
        return positions
    }

    /// One complete chain starting at `startIndex`, or nil when the position is
    /// not a chain head or the chain cannot be completed. Returning nil for an
    /// incomplete chain is deliberate: every member then falls back to a plain
    /// attack, which keeps the note-on/off stream balanced. A chain whose
    /// destination sits in the next measure lands here too — the walk sees one
    /// voice's elements at a time.
    private static func bendChain( // swiftlint:disable:this function_body_length
        positions: [ChainPosition],
        startingAt startIndex: Int,
    ) -> [(Int, BendChainSlot)]? {
        guard let head = positions[startIndex].note,
              let headBend = head.guitarBend,
              startsChain(headBend.type),
              let firstIndex = struckAt(positions: positions, bendingAt: startIndex),
              let first = positions[firstIndex].note
        else { return nil }
        let basePitch = head.pitch
        var chain: [(Int, BendChainSlot)] = []
        var offsetQuarterTones = 0
        var index = firstIndex
        var note = first
        while true {
            let bend = note.guitarBend.flatMap { startsChain($0.type) ? $0 : nil }
            let followerIndex = index + 1
            let follower = followerIndex < positions.count
                ? positions[followerIndex].note
                : nil
            // A member tied onward MUST hand the key to its tie partner. If it
            // cannot, the whole chain is dropped rather than half-applied: the
            // tie would otherwise suppress a note-on whose note-off the chain
            // had already emitted somewhere else.
            let tiedFollower = note.tieForward != nil
            if tiedFollower {
                guard let follower, follower.tieBack != nil,
                      follower.pitch == note.pitch
                else { return nil }
            }
            if let bend, bend.type != .slightBend {
                guard let follower, follower.guitarBendBack else { return nil }
                let target = (follower.pitch - basePitch) * 2
                chain.append((index, BendChainSlot(
                    basePitch: basePitch,
                    startOffsetQuarterTones: offsetQuarterTones,
                    targetOffsetQuarterTones: target,
                    isChainStart: chain.isEmpty, isChainEnd: false,
                    startTimeFactor: bend.startTimeFactor,
                    endTimeFactor: bend.endTimeFactor,
                )))
                offsetQuarterTones = target
                index = followerIndex
                note = follower
                continue
            }
            // A slight bend is a quarter-tone scoop with no notated
            // destination: it begins and ends on the same note, ramps up and
            // HOLDS — MuseScore never brings it back down. Everything else
            // here has no bend of its own and simply holds the wheel: either a
            // tie carries the chain onward, or this is its last member.
            chain.append((index, BendChainSlot(
                basePitch: basePitch,
                startOffsetQuarterTones: offsetQuarterTones,
                targetOffsetQuarterTones: bend.map { _ in offsetQuarterTones + 1 },
                isChainStart: chain.isEmpty, isChainEnd: !tiedFollower,
                startTimeFactor: bend?.startTimeFactor ?? 0,
                endTimeFactor: bend?.endTimeFactor ?? 1,
            )))
            if bend != nil { offsetQuarterTones += 1 }
            guard tiedFollower, let follower else { return chain }
            index = followerIndex
            note = follower
        }
    }

    /// Where the chain that bends at `index` is actually STRUCK: walking back
    /// over ties, because a note tied into is already sounding and its
    /// predecessor suppressed its own release. Striking at the bend instead
    /// would attack the key a second time while the first is still ringing.
    ///
    /// Returns nil when the tie leads out of reach — the partner is in another
    /// measure (the walk sees one measure's voice elements), or takes a render
    /// path this map cannot host. The chain is then dropped whole and every
    /// member keeps the plain rendering it had before bends existed.
    private static func struckAt(
        positions: [ChainPosition], bendingAt index: Int,
    ) -> Int? {
        var index = index
        while let note = positions[index].note, note.tieBack != nil {
            let previousIndex = index - 1
            guard previousIndex >= 0,
                  let previous = positions[previousIndex].note,
                  previous.tieForward != nil, previous.pitch == note.pitch
            else { return nil }
            index = previousIndex
        }
        return index
    }

    /// Whether a bend type opens (or extends) a pitch-curving chain in v1.
    /// See `guitarBendChains` for why the other five do not.
    private static func startsChain(_ type: GuitarBendType) -> Bool {
        switch type {
        case .bend, .slightBend, .graceNoteBend: true
        case .preBend, .dive, .preDive, .dip, .scoop: false
        }
    }

    /// Element indices a `.between` tremolo swallows, mirroring the lookup in
    /// `renderTremoloChord`: the next `.chord` element after each `.between`
    /// chord, rests included (the tremolo pairs with whatever chord element
    /// follows, exactly as MuseScore's editor re-pairs it).
    private static func tremoloConsumedIndices(in voiceElements: [VoiceElement]) -> Set<Int> {
        var consumed: Set<Int> = []
        for (index, element) in voiceElements.enumerated() {
            guard case let .chord(chord) = element,
                  chord.tremolo?.span == .between
            else { continue }
            for j in (index + 1) ..< voiceElements.count {
                if case .chord = voiceElements[j] {
                    consumed.insert(j)
                    break
                }
            }
        }
        return consumed
    }
}
