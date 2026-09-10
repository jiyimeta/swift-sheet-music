import SheetMusicFoundation

/// Shows or hides ONE piece of engraved text — a lyric syllable, a staff or system text, a chord symbol, or a
/// rehearsal mark — named the way a click names it, by `ScoreTextID`.
///
/// ## Why this exists next to `SetElementVisible`
///
/// `SetElementVisible` takes a `VoiceElementID`, and three of the four text kinds have none of their own: a
/// `Lyric` is a field of the chord's `lyrics` array, and a `StaffText` / `RehearsalMark` is a `SystemElement` in
/// `Score.systemMeasures`. Aiming `SetElementVisible` at a `ScoreTextID`'s anchor would hide the CHORD the text
/// hangs from — the note a user aimed a click past.
///
/// The fourth kind, a chord symbol, IS a voice element that `SetElementVisible` already accepts, and this command
/// does not re-implement its write: the `.harmony` arm resolves the slot and applies `SetElementVisible` to it.
/// What was missing for a chord symbol was never the write but the ADDRESS — `ScoreTextID.harmony(anchor:)`
/// carries the chord the symbol names, not the symbol's own index, and the run search that turns one into the
/// other (`AdjacentElementSlot`, via `SetChordSymbol.harmonySlot`) is internal to this module, so no host could
/// perform it. Owning that resolution is this command's job for the harmony case, exactly as `SetChordSymbol`
/// owns the same adjacency rule for the symbol's text.
///
/// One command over the four kinds rather than one per kind, for the reason `ScoreTextID` is one nested type
/// rather than four flat `ScoreItemID` cases: what a host has in hand is a single identity a click produced, and
/// a properties panel asking "hide this" should not have to know which of four storage shapes the answer lives
/// in. The kinds differ in where the flag is written, not in what the operation means.
///
/// ## Semantics
///
/// Playback is unaffected — `ElementProperties.visible` is an engraving flag (`SetElementVisible`'s own doc
/// comment). Only the named text's flag moves; nothing cascades to the chord it hangs from, to a lyric's hyphen
/// or melisma line, or to the other syllables of its verse — a text selection is per element, never per row
/// (`ScoreTextID`'s own doc comment, from MuseScore's `Lyrics` being one `EngravingItem` per syllable).
///
/// A `ScoreTextID` that names no text in `score` — a verse the chord does not carry, a beat with no staff text of
/// that kind, a bar with no rehearsal mark — is refused as `.targetNotFound`, so a stale selection cannot mint an
/// undo step that changes nothing.
///
/// > Note: For the `.harmony` case this is sugar over `SetElementVisible`, which is itself sugar over
/// > `ReplaceVoiceElement`. The other three arms write model fields no other command reaches. See
/// > `docs/edit-commands.md`.
public struct SetTextVisible: EditCommand {
    public let text: ScoreTextID
    public let visible: Bool

    public init(_ text: ScoreTextID, visible: Bool) {
        self.text = text
        self.visible = visible
    }

    /// The anchor the text hangs from — or, for a rehearsal mark, which has none, the bar-addressing
    /// approximation `SetRehearsalMark.affectedLocation` already reports (part 0 / staff 0 / voice 0 /
    /// element 0), since the session only reads `measureIndex` off it.
    public var affectedLocation: VoiceElementID {
        text.anchor ?? VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: Self.measureIndex(of: text), voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let old = Self.current(text, in: score) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        switch text {
        case let .lyric(anchor, verse):
            guard case var .chord(chord) = score[anchor], chord.lyrics.indices.contains(verse) else {
                throw Self.refused(.targetNotFound(affectedLocation))
            }
            chord.lyrics[verse].visible = visible
            score[anchor] = .chord(chord)
        case let .staffText(anchor, style):
            guard let slot = SetStaffText.laneSlot(
                at: anchor, isSystemText: style == .systemText, in: score,
            ), case var .staffText(mark) = score.systemMeasures[slot.measureIndex].elements[slot.elementIndex]
                .element
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            mark.visible = visible
            score.systemMeasures.updateValue(at: slot.measureIndex) {
                $0.elements.updateValue(at: slot.elementIndex) { $0.element = .staffText(mark) }
            }
        case let .harmony(anchor):
            guard let slot = SetChordSymbol.harmonySlot(at: anchor, in: score) else {
                throw Self.refused(.targetNotFound(affectedLocation))
            }
            try SetElementVisible(at: slot, visible: visible).apply(to: &score, ids: &ids)
        case let .rehearsalMark(measureIndex):
            guard score.systemMeasures.indices.contains(measureIndex),
                  let index = RehearsalMarkLane.markIndex(in: score.systemMeasures[measureIndex]),
                  case var .rehearsalMark(mark) = score.systemMeasures[measureIndex].elements[index].element
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            mark.visible = visible
            score.systemMeasures.updateValue(at: measureIndex) {
                $0.elements.updateValue(at: index) { $0.element = .rehearsalMark(mark) }
            }
        }
        return SetTextVisible(text, visible: old)
    }

    /// The flag on the text `id` names, or `nil` when the score carries no such text.
    ///
    /// **Public, unlike every other command's `current`.** A host's properties panel has to decide whether the
    /// Show / Hide row is live before it sends anything, and for three of the four kinds there is no other way to
    /// find out from outside this module: the staff-text match rule (kind, beat and staff) lives in
    /// `SetStaffText`, the "first mark in the bar" premise in `RehearsalMarkLane`, and the chord symbol's own slot
    /// behind `AdjacentElementSlot`. Reading it here is what keeps the host's answer and this command's answer the
    /// same lookup.
    public static func current(_ id: ScoreTextID, in score: Score) -> Bool? {
        switch id {
        case let .lyric(anchor, verse):
            // Includes a padding entry with empty text, which `SetLyric` mints for the verses below one that was
            // written. Nothing engraves such an entry, so a click cannot name one; an intent built directly can,
            // and flipping its flag is harmless — `SetLyric`'s removal trims it by emptiness either way.
            return SetLyric.current(at: anchor, verse: verse, in: score)?.visible
        case let .staffText(anchor, style):
            return SetStaffText.laneMark(at: anchor, isSystemText: style == .systemText, in: score)?.visible
        case let .harmony(anchor):
            return SetChordSymbol.current(at: anchor, in: score)?.visible
        case let .rehearsalMark(measureIndex):
            return RehearsalMarkLane.mark(in: score, measureIndex: measureIndex)?.visible
        }
    }

    /// The bar a rehearsal mark addresses. Only reached for that case; the other three answer through `anchor`.
    private static func measureIndex(of id: ScoreTextID) -> Int {
        if case let .rehearsalMark(measureIndex) = id { measureIndex } else { 0 }
    }
}
