import SheetMusicFoundation

/// The staves a key signature is written on, and the one the engine reads the score's key from.
///
/// Percussion is excluded with the same spelling `AddPart.signatureReference(in:)` and
/// `MeasureAccidentals.renotationCommands(in:measureRange:)` use — a `useDrumset` part, or a staff whose `group` is
/// `"percussion"`. Unpitched staves have no key to be in or out of, and `Score.blank(_:)` already strips key
/// signatures off the bars it builds for them, so writing one here would put back exactly what that strip removed.
enum KeySignatureStaves {
    /// Every pitched staff, in document order.
    static func addresses(in score: Score) -> [StaffAddress] {
        var addresses: [StaffAddress] = []
        for (partIndex, part) in score.parts.enumerated() where !part.instrument.useDrumset {
            for (staffIndex, staff) in part.staves.enumerated() where staff.group != "percussion" {
                addresses.append(StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex))
            }
        }
        return addresses
    }

    /// The staff the score's key is read from: the first pitched one. `nil` for a score of drum kits alone, which
    /// declares no key anywhere and so has nothing for these commands to change.
    static func reference(in score: Score) -> StaffAddress? {
        addresses(in: score).first
    }

    /// The explicit key `measureIndex` declares on `staff`, or `nil` when that bar declares none and simply
    /// inherits whatever is already in force.
    ///
    /// Scoped to the LEADING signature run — a key signature written after a note is a mid-bar change, which is
    /// neither what a host means by "the key at this bar" nor something these commands claim to manage.
    static func explicitKey(in score: Score, staff: StaffAddress, measureIndex: Int) -> KeySignature? {
        guard let staff = score[staff], staff.measures.indices.contains(measureIndex),
              let voice = staff.measures[measureIndex].voices.first
        else { return nil }
        for element in MeasureStructure.leadingSignaturePrefix(of: voice) {
            if case let .keySignature(key) = element { return key }
        }
        return nil
    }
}

/// Writes `concertKey` into `measureIndex`'s leading signature run on every pitched staff — replacing the key that
/// bar already declares, or inserting one where it declared none.
///
/// The command is deliberately narrow: it changes what ONE bar declares, and the key it declares runs until the next
/// bar that declares its own. Re-spelling the notes over that span is the planner's job
/// (`ScoreEditSession+Planning`), not this command's — the span is a property of the score around the edit, while
/// this is the edit itself, and keeping them apart is what lets `RemoveKeySignature` reuse the same span logic.
///
/// ## The inverse
///
/// A key write is not reversible by arithmetic. The bar may have declared no key at all (so the inverse must remove
/// one, shifting the elements after it back), or declared one carrying a `visible` / `showCourtesy` flag this write
/// does not preserve on the insert path. So the inverse carries the pre-image: every staff's voice-0 leading run at
/// `measureIndex`, restored verbatim by `init(restoringPrefixes:at:)` — the idiom `InsertMeasure(measureIndex:
/// restoredContents:...)` and `AddPart(restoring:at:...)` already use.
///
/// The pre-image covers EVERY staff, percussion included, even though the write skips those: restoring a run to
/// itself costs nothing, and a capture that skipped staves would have to re-derive which ones it skipped against a
/// score the inverse is not allowed to assume is unchanged.
public struct SetKeySignature: EditCommand {
    public let measureIndex: Int
    /// The concert key to write (`-7…+7`, sharps positive). On the restore path this is the key the captured
    /// prefixes put back — `apply` ignores it there and splices the pre-image instead.
    public let concertKey: Int
    /// Set only when this command is the inverse of a `SetKeySignature` / `RemoveKeySignature`: every staff's
    /// voice-0 leading signature run at `measureIndex` as it stood before that edit, indexed
    /// `[partIndex][staffIndexInPart]`.
    let restoredPrefixes: [[[VoiceElement]]]?

    public init(measureIndex: Int, concertKey: Int) {
        self.measureIndex = measureIndex
        self.concertKey = concertKey
        restoredPrefixes = nil
    }

    init(restoringPrefixes prefixes: [[[VoiceElement]]], at measureIndex: Int) {
        self.measureIndex = measureIndex
        concertKey = Self.keyCarried(by: prefixes)
        restoredPrefixes = prefixes
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        // One place states the range, for the same reason `AddPart` does: the answer is the same whether the
        // command is reached through an intent or built directly.
        guard measureIndex >= 0, measureIndex < MeasureStructure.measureCount(of: score), !score.parts.isEmpty
        else { throw Self.refused(.targetNotFound(affectedLocation)) }

        let previous = SignaturePrefixes.captured(from: score, at: measureIndex)
        if let restoredPrefixes {
            SignaturePrefixes.splice(restoredPrefixes, into: &score, at: measureIndex)
        } else {
            for address in KeySignatureStaves.addresses(in: score) {
                SignaturePrefixes.mutateVoiceZero(of: &score, at: address, measureIndex: measureIndex) { voice in
                    Self.write(concertKey, into: &voice)
                }
            }
        }
        return SetKeySignature(restoringPrefixes: previous, at: measureIndex)
    }

    /// Replaces the key already in `voice`'s leading run, or inserts one at the canonical position when the bar
    /// declares none.
    ///
    /// Canonical is `MeasureStructure.mergedLeadingSignatures`' order — clef, then key, then time — which here
    /// means "before the run's time signature, after everything else in it". That merge is not called directly
    /// because it resolves at most one element of each kind: a bar carrying two clefs would come back with one,
    /// and this command has no business dropping an element it was not asked about.
    ///
    /// The replace path mutates the key in place rather than substituting a fresh `KeySignature`, so an invisible
    /// or courtesy-suppressed signature stays that way — this intent states which key, not how it is drawn.
    private static func write(_ concertKey: Int, into voice: inout Voice) {
        let prefix = MeasureStructure.leadingSignaturePrefix(of: voice)
        if let existing = prefix.firstIndex(where: { if case .keySignature = $0 { true } else { false } }) {
            guard case var .keySignature(key) = voice.elements[existing] else { return }
            key.concertKey = concertKey
            voice.elements[existing] = .keySignature(key)
            return
        }
        let insertion = prefix.firstIndex { if case .timeSignature = $0 { true } else { false } } ?? prefix.count
        voice.elements.insert(.keySignature(KeySignature(concertKey: concertKey)), at: insertion)
        MeasureStructure.shiftTuplets(in: &voice, by: 1)
    }

    /// The key a captured pre-image declares — the first one any staff's run carries, or C major when none does
    /// (a restore that removes the bar's key again). Read only to keep `concertKey` truthful on the restore path.
    private static func keyCarried(by prefixes: [[[VoiceElement]]]) -> Int {
        for part in prefixes {
            for prefix in part {
                for element in prefix {
                    if case let .keySignature(key) = element { return key.concertKey }
                }
            }
        }
        return 0
    }
}

/// Removes the explicit key change at `measureIndex` from every pitched staff, so the bar inherits whatever key was
/// already in force.
///
/// Refused at measure 0 with `.cannotRemoveInitialSignature`: bar 1's signature is the score's key rather than a
/// change to it, and a score with no key at all is not something the engraver, the MSCX encoder or a host's key
/// picker has a representation for. `.setKeySignature` is how bar 1 changes what it declares.
///
/// Refused with `.targetNotFound` when the bar declares no key to remove. That case is the PLANNER's to resolve to
/// nothing (`ScoreEditSession+Planning` returns `nil`, which the session reports as `.nothingToApply`); the throw
/// here is what the same command answers when it is built directly, so the range and the emptiness are both stated
/// in one place.
public struct RemoveKeySignature: EditCommand {
    public let measureIndex: Int

    public init(measureIndex: Int) {
        self.measureIndex = measureIndex
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard measureIndex >= 0, measureIndex < MeasureStructure.measureCount(of: score), !score.parts.isEmpty
        else { throw Self.refused(.targetNotFound(affectedLocation)) }
        guard measureIndex > 0 else { throw Self.refused(.cannotRemoveInitialSignature) }

        let previous = SignaturePrefixes.captured(from: score, at: measureIndex)
        var removed = false
        for address in KeySignatureStaves.addresses(in: score) {
            SignaturePrefixes.mutateVoiceZero(of: &score, at: address, measureIndex: measureIndex) { voice in
                removed = Self.removeKey(from: &voice) || removed
            }
        }
        guard removed else { throw Self.refused(.targetNotFound(affectedLocation)) }
        return SetKeySignature(restoringPrefixes: previous, at: measureIndex)
    }

    /// Drops every key signature sitting in `voice`'s LEADING run, reporting whether it found one.
    ///
    /// Not `MeasureStructure.removeElements(in:where:)`: that predicate sees values, not positions, so it cannot
    /// tell the run's key from a mid-bar key change written after a note — and removing the latter would silently
    /// take a change this command was never asked about. The removals here all fall in the run at the head of the
    /// element list, so every tuplet (which spans chords and rests, always after the run) shifts by the same
    /// amount, and `shiftTuplets(in:by:)` is the exact remap — the same reasoning `InsertMeasure` uses when it
    /// lifts bar 0's whole run out.
    private static func removeKey(from voice: inout Voice) -> Bool {
        let prefixCount = MeasureStructure.leadingSignaturePrefix(of: voice).count
        let indices = voice.elements.indices.prefix(prefixCount).filter {
            if case .keySignature = voice.elements[$0] { true } else { false }
        }
        guard !indices.isEmpty else { return false }
        for index in indices.reversed() {
            voice.elements.remove(at: index)
        }
        MeasureStructure.shiftTuplets(in: &voice, by: -indices.count)
        return true
    }
}

/// The prefix splice both key-signature commands share: capture one measure's leading signature runs across the
/// whole score, and put them back.
enum SignaturePrefixes {
    /// Every staff's voice-0 leading signature run at `measureIndex`, indexed `[partIndex][staffIndexInPart]`. A
    /// staff that is short of that measure — or whose measure has no voices — contributes an empty run, which
    /// `splice` then skips over rather than writing.
    static func captured(from score: Score, at measureIndex: Int) -> [[[VoiceElement]]] {
        score.parts.map { part in
            part.staves.map { staff in
                guard staff.measures.indices.contains(measureIndex),
                      let voice = staff.measures[measureIndex].voices.first
                else { return [] }
                return MeasureStructure.leadingSignaturePrefix(of: voice)
            }
        }
    }

    /// Writes a captured pre-image back over whatever leading run each staff carries now, re-shifting tuplets by
    /// the length difference.
    ///
    /// Whole-value overwrite of the run rather than an arithmetic undo, for the reason
    /// `InsertMeasure.restoredIncomingVoice0` gives: the forward edit can insert, replace or remove within the
    /// run, and only the pre-image knows which — down to the `visible` / `showCourtesy` flags on the element that
    /// was replaced.
    static func splice(_ prefixes: [[[VoiceElement]]], into score: inout Score, at measureIndex: Int) {
        for partIndex in score.parts.indices where prefixes.indices.contains(partIndex) {
            for staffIndex in score.parts[partIndex].staves.indices
                where prefixes[partIndex].indices.contains(staffIndex)
            {
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                let restored = prefixes[partIndex][staffIndex]
                mutateVoiceZero(of: &score, at: address, measureIndex: measureIndex) { voice in
                    let current = MeasureStructure.leadingSignaturePrefix(of: voice).count
                    voice.elements.replaceSubrange(0 ..< current, with: restored)
                    MeasureStructure.shiftTuplets(in: &voice, by: restored.count - current)
                }
            }
        }
    }

    /// Runs `mutate` over one staff's voice 0 at `measureIndex`, or does nothing when that voice is not there —
    /// a staff shorter than the score, or a measure carrying no voices at all.
    static func mutateVoiceZero(
        of score: inout Score, at address: StaffAddress, measureIndex: Int, _ mutate: (inout Voice) -> Void,
    ) {
        let partIndex = address.partIndex
        let staffIndex = address.staffIndexInPart
        guard score.parts.indices.contains(partIndex),
              score.parts[partIndex].staves.indices.contains(staffIndex),
              score.parts[partIndex].staves[staffIndex].measures.indices.contains(measureIndex),
              !score.parts[partIndex].staves[staffIndex].measures[measureIndex].voices.isEmpty
        else { return }
        mutate(&score.parts[partIndex].staves[staffIndex].measures[measureIndex].voices[0])
    }
}
