import SheetMusicFoundation

/// Writes a new meter at `measureIndex` and RE-BARS the span it governs: the content from that bar to the next
/// explicit time change (or the end of the score) is re-partitioned into bars of the new length, notes the new
/// barlines cut are split and tied, and the score's measure count may change. One undo step.
///
/// The re-partition itself is `RebarPlanner`'s — it reads the region and answers with the replacement columns,
/// mutating nothing. What this command owns is everything around that: which bars the region is, what they looked
/// like before, splicing the answer back over them, and restating the spanners whose span the new bar count moved.
///
/// ## The inverse
///
/// A re-bar is not reversible by arithmetic: it re-spells rhythms, re-homes system elements and barline markers,
/// and changes how many bars there are. So the inverse carries the pre-image — the region's columns exactly as
/// they stood, plus the endpoints of every spanner anchored OUTSIDE it that had to be restated (one anchored
/// inside rides back in with the columns) — restored verbatim by `RestoreTimeSignatureRegion`. The idiom
/// `InsertMeasure(measureIndex:restoredContents:...)` and `SetKeySignature(restoringPrefixes:at:)` already use,
/// one level up: a whole measure column rather than a leading signature run.
///
/// ## Irregular bars at the head
///
/// `RebarPlanner` passes an irregular bar (a pickup, or any bar declaring its own `actualLength`) through
/// verbatim and declares the new meter on the first REGULAR column instead. At the head of the region that is one
/// bar too late — and on a region made entirely of irregular bars it is nowhere at all, which would leave the edit
/// with no effect. So when the region opens on an irregular bar the planner is told to declare nothing and this
/// command writes the meter into that bar itself: replacing the signature it already carries, in place, or
/// inserting one where it carried none. Its `actualLength` and its content are never touched — a pickup in 3/4 is
/// still one quarter long.
public struct SetTimeSignature: EditCommand {
    public let measureIndex: Int
    public let numerator: Int
    public let denominator: Int

    public init(measureIndex: Int, numerator: Int, denominator: Int) {
        self.measureIndex = measureIndex
        self.numerator = numerator
        self.denominator = denominator
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        // One place states the range, for the same reason `SetKeySignature` does: the answer is the same whether
        // the command is reached through an intent or built directly.
        guard measureIndex >= 0, measureIndex < MeasureStructure.measureCount(of: score), !score.parts.isEmpty
        else { throw Self.refused(.targetNotFound(affectedLocation)) }
        guard TimeSignatureRegion.isWritable(numerator: numerator, denominator: denominator) else {
            throw Self.refused(.invalidTimeSignatureValue(numerator: numerator, denominator: denominator))
        }
        return try TimeSignatureRegion.rebar(
            &score, from: measureIndex,
            to: TimeSignature(numerator: numerator, denominator: denominator),
            declaringAtHead: true,
        )
    }
}

/// Removes the explicit time change at `measureIndex`, re-barring its span back to the meter that was already in
/// force before it.
///
/// Refused at measure 0 with `.cannotRemoveInitialSignature`, for the reason `RemoveKeySignature` gives: bar 1's
/// signature is the score's meter rather than a change to it, and a score declaring none is not something the
/// engraver, the MSCX encoder or a host's meter picker has a representation for. `.setTimeSignature` is how bar 1
/// changes what it declares.
///
/// Refused with `.targetNotFound` when the bar declares no meter to remove. That case is the PLANNER's to resolve
/// to nothing (`ScoreEditSession+SignaturePlanning` returns `nil`, which the session reports as
/// `.nothingToApply`); the throw here is what the same command answers when it is built directly.
///
/// Everything past that is `SetTimeSignature`'s machinery reached with the PREVAILING signature, and with the
/// planner told to declare nothing: a removal must leave the span carrying no explicit meter of its own, so the
/// one it inherits is the one that reaches it.
public struct RemoveTimeSignature: EditCommand {
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
        guard TimeSignatureRegion.explicitSignature(in: score, measureIndex: measureIndex) != nil else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        return try TimeSignatureRegion.rebar(
            &score, from: measureIndex,
            to: TimeSignatureRegion.signature(inForceBefore: measureIndex, in: score),
            declaringAtHead: false,
        )
    }
}

/// The inverse both meter commands return: splices `columns` back over `range` and restores the captured spanner
/// offsets verbatim.
///
/// Its own inverse is another instance of itself, built from a pre-image captured BEFORE the splice — so undo and
/// redo cycle through one code path rather than two that have to agree. `range` is always the range the columns it
/// is replacing occupy right now; the range IT leaves behind is `range.lowerBound` plus however many columns it
/// wrote, which is what the returned inverse names.
struct RestoreTimeSignatureRegion: EditCommand {
    let range: Range<Int>
    let columns: [MeasureSlice]
    /// Only the spanners anchored BEFORE the region whose endpoint the re-bar restated. One anchored inside it is
    /// not here and does not need to be: it lives in a column, and `columns` puts that column back verbatim.
    let spannerEndpoints: [TimeSignatureRegion.SpannerEndpoint]

    var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: range.lowerBound, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    func apply(to score: inout Score) throws -> any EditCommand {
        guard range.lowerBound >= 0, range.upperBound <= MeasureStructure.measureCount(of: score),
              !score.parts.isEmpty
        else { throw Self.refused(.targetNotFound(affectedLocation)) }

        let previousColumns = TimeSignatureRegion.capturedColumns(of: score, over: range)
        let previousEndpoints = TimeSignatureRegion.currentEndpoints(for: spannerEndpoints, in: score)
        TimeSignatureRegion.splice(columns, into: &score, replacing: range)
        TimeSignatureRegion.writeEndpoints(spannerEndpoints, into: &score)
        return RestoreTimeSignatureRegion(
            range: range.lowerBound ..< range.lowerBound + columns.count,
            columns: previousColumns,
            spannerEndpoints: previousEndpoints,
        )
    }
}

extension TimeSignatureRegion {
    /// Re-bars the span `measureIndex` governs at `signature`, splices it in, and answers with the inverse.
    ///
    /// `declaringAtHead` is the whole difference between the two commands: setting writes the new meter at the
    /// head of the region, removing writes nothing at all and lets the span inherit what was already in force.
    ///
    /// Ordering matters and is deliberate: everything before the splice only READS the score, so a refusal thrown
    /// by `RebarPlanner` — a tuplet the new barring would split, a repeat sign it would displace — propagates with
    /// the score exactly as it was.
    static func rebar(
        _ score: inout Score, from measureIndex: Int, to signature: TimeSignature, declaringAtHead: Bool,
    ) throws -> RestoreTimeSignatureRegion {
        let end = nextExplicitChange(after: measureIndex, in: score)
            ?? MeasureStructure.measureCount(of: score)
        let region = measureIndex ..< end
        let headIsIrregular = isIrregular(measureIndex, in: score)
        var columns = try RebarPlanner.rebar(
            region: region, in: score,
            numerator: signature.numerator, denominator: signature.denominator,
            emitsLeadingSignature: declaringAtHead && !headIsIrregular,
        ).columns
        if headIsIrregular, !columns.isEmpty {
            if declaringAtHead {
                declare(signature, in: &columns[0])
            } else {
                removeSignatures(from: &columns[0])
            }
        }

        let previousColumns = capturedColumns(of: score, over: region)
        // Rewrites the inside-anchored spanners in `columns` and hands back the outside-anchored ones, whose
        // addresses only become writable once the splice has happened.
        let endpoints = restatingSpannerEndpoints(
            &columns, region: region, signature: signature, in: score,
        )
        splice(columns, into: &score, replacing: region)
        writeEndpoints(endpoints.map(\.restated), into: &score)
        return RestoreTimeSignatureRegion(
            range: measureIndex ..< measureIndex + columns.count,
            columns: previousColumns,
            spannerEndpoints: endpoints.map(\.previous),
        )
    }
}
