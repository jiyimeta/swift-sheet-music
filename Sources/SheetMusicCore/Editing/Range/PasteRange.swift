import SheetMusicFoundation

/// Writes the material a clipboard payload carries into the score at `location`, overwriting from there — ⌘V for
/// a range copy, and the sibling of `DuplicateRange`.
///
/// The payload is a small, self-contained `.mscx` document holding just the copied bars (`RangeCopyPayload`
/// writes it), so it may have come from another score, another window, or a previous run of the app. Once it has
/// been read back into a `Score` the two commands are the same command: the material is resolved by
/// `RangeCopySource`, re-addressed onto the destination's staves, and handed to the shared write pass, so every
/// rule a duplicate obeys a paste obeys too — an element cut by a barline becomes a tied chain, a tuplet survives
/// only where all of its members fit one destination bar, a destination tuplet the paste cuts is destroyed and
/// refilled, the destination's annotations are cleared and superseded, slurs and lines wholly inside the payload
/// are re-anchored, ties are sealed across the destination barline, and measure columns are appended when the
/// material runs past the last bar.
///
/// The payload's staves land in display order starting at `location.staff`, so pasting a two-staff copy onto the
/// second staff of a score writes staves two and three. Voice indices are not shifted.
///
/// > Note: This command is sugar over `InsertMeasure` (× appended bar) + `CreateVoice` (× missing voice) +
/// > `ReplaceVoiceElements` (× destination bar-voice) bundled in a `CompositeEditCommand`, so one undo reverses
/// > the whole paste, appended measures included. See `docs/edit-commands.md`.
public struct PasteRange: EditCommand, RangeCopyWriting {
    /// Turns a payload's bytes into a `Score`. In this package that is always `MSCXParser.parse`, and it is a
    /// parameter rather than a call because `SheetMusicMSCX` depends on `SheetMusicCore` — importing it from
    /// here is a module cycle the compiler rejects outright, so the reader has to arrive from a module that can
    /// see both. A host passes `MSCXParser.parse` once, at the seam where it already links the format.
    public typealias PayloadReader = @Sendable (Data) throws -> Score

    /// Where the payload's first staff and first tick land.
    public let location: VoiceElementID
    /// The `.mscx` document to paste, as text.
    public let payload: String
    let readPayload: PayloadReader

    public init(at location: VoiceElementID, payload: String, readPayload: @escaping PayloadReader) {
        self.location = location
        self.payload = payload
        self.readPayload = readPayload
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let composite = try plan(in: score, ids: ids) else {
            return CompositeEditCommand(commands: [], location: location)
        }
        return try composite.apply(to: &score, ids: &ids)
    }

    /// The composite this command would apply to `score`, or `nil` when it would change nothing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned
    /// one refuse identically, and — because `score` is only read until the composite is applied — every refusal
    /// below leaves the score exactly as it was.
    ///
    /// Reading the payload comes first, before anything is resolved or planned, so unusable bytes cost nothing.
    func plan(in score: Score, ids: EIDAllocator) throws -> CompositeEditCommand? {
        let payloadScore = try readPayloadScore()
        guard let resolved = RangeCopySource(payload: payloadScore) else {
            throw Self.refused(Self.refusalReason(forUnusable: payloadScore, at: location))
        }
        guard let source = resolved.relocated(from: payloadScore, onto: location.staff, in: score) else {
            throw Self.refused(.staffNotFound(location.staff))
        }
        guard let onset = score.onset(of: location),
              let destinationTick = RangeCopyGeometry(staff: location.staff, in: score).absolute(onset)
        else {
            throw Self.refused(.targetNotFound(location))
        }
        // The destination tick was just measured on `location.staff`, so that is the axis every stream's
        // placement is stated against — never the first staff that happens to carry material.
        let commands = try writeCommands(
            for: source, at: destinationTick, onAxisOf: location.staff, in: score, ids: ids,
        )
        return commands.isEmpty ? nil : CompositeEditCommand(commands: commands, location: location)
    }
}

extension PasteRange {
    /// The payload parsed back into a score, or `.unreadablePayload`.
    ///
    /// Every way the reader can fail collapses into the one reason on purpose: a host cannot act differently on
    /// "not XML at all" than on "XML that is not a score", and the underlying error is a parser's, phrased for a
    /// file the user chose to open rather than for bytes that happened to be on a pasteboard.
    private func readPayloadScore() throws -> Score {
        do {
            return try readPayload(Data(payload.utf8))
        } catch {
            throw Self.refused(.unreadablePayload)
        }
    }

    /// Why `RangeCopySource.init?(payload:)` came back `nil`.
    ///
    /// That initializer is non-throwing and collapses two different failures into `nil`: a payload with no chord
    /// or rest in it at all, and a payload whose own extent cuts a tuplet. MuseScore tells the user which — its
    /// list paste raises `DEST_TUPLET` as its own dialog (`mscoreerrorscontroller.cpp:124-152`) — so the
    /// information has somewhere to go, and this recovers it by re-running the initializer's own two steps
    /// rather than by re-deriving what either of them decides. The cost is a second resolution of a paste that
    /// is already being refused.
    ///
    /// `.insideTuplet` is re-addressed to `location` deliberately. The bound the resolution refused is a slot in
    /// the PAYLOAD, whose measure and staff numbering means nothing in the score the host is showing; the slot
    /// the user can actually be pointed at is the one they tried to paste onto.
    private static func refusalReason(forUnusable payload: Score, at location: VoiceElementID)
        -> EditRefusal.Reason
    {
        guard let first = RangeCopySource.firstTimedSlot(in: payload),
              let last = RangeCopySource.lastTimedSlot(in: payload)
        else { return .emptyPayload }
        do {
            _ = try RangeCopySource(range: VoiceElementRange(start: first, end: last), in: payload)
            return .targetNotFound(location)
        } catch let SheetMusicError.invalidEdit(refusal) {
            if case .insideTuplet = refusal.reason { return .insideTuplet(at: location) }
            return refusal.reason
        } catch {
            return .targetNotFound(location)
        }
    }
}
