#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutDocument {
    /// The final lyric ink anchor, including authored offsets. Empty rows resolve through
    /// the supplied style context; the displayed cursor remains the only address used here.
    public func lyricEntryOrigin(
        at cursor: LyricInputPlanner.Cursor,
        placementStyle: TextPlacementStyles? = nil,
        elementProperties: ElementProperties = .default,
    ) -> CGPoint? {
        for system in systems {
            for measure in system.measures where measure.measureIndex == cursor.location.measureIndex {
                for element in measure.elements {
                    guard case let .textMark(.lyrics(_, verse, anchor, _), _, point) = element,
                          anchor == cursor.location, verse == cursor.verse else { continue }
                    return absolute(point, in: system, measure: measure)
                }
            }
        }
        guard let anchor = chordStemOrigin(at: cursor.location),
              let y = lyricLineY(
                  at: cursor.location,
                  verse: cursor.verse,
                  placementStyle: placementStyle,
                  elementProperties: elementProperties,
              )
        else { return nil }
        let style = placementStyle ?? TextPlacementStyles()
        let side = style.side(for: .lyrics, element: elementProperties)
        let x = style.position(for: .lyrics, side: side).x + (elementProperties.offset?.x ?? 0)
        return CGPoint(x: anchor.x + CGFloat(x) * metrics.sp, y: y)
    }

    /// The final document-space origin of a chord stem or rest at `anchor`.
    /// Used only as a deterministic empty-editor fallback when no pending
    /// engraved text exists yet.
    public func timedElementOrigin(
        at anchor: VoiceElementID,
    ) -> CGPoint? {
        if let chord = chordStemOrigin(at: anchor) {
            return chord
        }
        let restID = RestID(
            staff: anchor.staff,
            measureIndex: anchor.measureIndex,
            voiceIndex: anchor.voiceIndex,
            elementIndex: anchor.elementIndex,
        )
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == anchor.measureIndex
            {
                for element in measure.elements {
                    guard case let .rest(_, origin, _, candidate, _) = element,
                          candidate == restID
                    else { continue }
                    return absolute(
                        origin, in: system, measure: measure,
                    )
                }
            }
        }
        return nil
    }

    /// The final document-space origin of the staff- or system-text glyph anchored at `anchor`.
    ///
    /// Matched on the identity `placeMeasureElements` carried onto the element, not on the string it prints:
    /// two "solo"s in one bar are two marks, and a lookup that could only compare text had to rank them by
    /// proximity and could pick the wrong one. `style` still narrows the search because one beat can carry both
    /// a staff text and a system text — `SetStaffText` writes them as distinct marks at the same anchor.
    ///
    /// ## What `nil` means, and the two anchors that cannot match
    ///
    /// `nil` is not "the mark is not engraved". A caller re-editing an EXISTING, non-empty mark has nothing to
    /// fall back on — the empty-editor fallback in the example overlay is gated on the editor being empty
    /// (`ScoreTextEntryOverlay.textEntryOrigin`) — so a miss here shows up as NO CARET AT ALL, not as a caret
    /// in a worse place. The text-and-proximity lookup this replaced always returned something, so these two
    /// cases are a regression in exchange for never returning the wrong element.
    ///
    /// 1. **Another voice at the same beat.** A lane mark has no voice: `SetStaffText` reduces any anchor it is
    ///    given to a `MeasurePosition`. Layout must still name one voice element, and picks the lowest-numbered
    ///    voice with a chord or rest at that beat. Pass an anchor from voice 2 of a bar whose beat also has a
    ///    voice-1 chord and this returns `nil`; the voice-1 anchor for the same mark answers.
    /// 2. **A system text queried from any staff but the canonical one.** `SetStaffText` writes a system text
    ///    with `originalStaff: nil` (it belongs to no staff), and `LayoutEngine` places a staff-less lane
    ///    element on the canonical staff only — one glyph, carrying a staff-(0,0) anchor. So
    ///    `staffTextOrigin(at:style: .systemText)` returns `nil` for EVERY anchor outside part 0 / staff 0,
    ///    which in a multi-part score is most of them.
    ///
    /// **Both are fixed by `staffTextOrigin(at:style:in:)`**, which matches by beat instead of by element
    /// index. This overload stays because it needs no `Score`, and because a caller that genuinely means "the
    /// mark whose emitted identity is exactly this" — a test pinning the emission, the JNI bridge's
    /// identity-keyed path — should not silently start matching a neighbouring voice. New caret paths want the
    /// beat-matching one.
    public func staffTextOrigin(
        at anchor: VoiceElementID,
        style: TextStyleType,
    ) -> CGPoint? {
        firstOrigin(inMeasure: anchor.measureIndex) { element in
            guard case let .staffText(_, origin, _, candidateStyle, candidateAnchor, _) = element,
                  candidateAnchor == anchor,
                  candidateStyle == style
            else { return nil }
            return origin
        }
    }

    /// The final document-space origin of the staff- or system-text glyph at `anchor`'s BEAT, matched through
    /// `score` rather than by element index.
    ///
    /// A lane mark is addressed by beat and staff, never by voice or by slot: `SetStaffText` reduces whatever
    /// anchor it is handed to a `MeasurePosition` (`SystemLaneSlot.position(of:in:)`). Layout must still name
    /// one voice element when it emits the glyph, and `LayoutEngine.systemLaneAnchor(atTick:…)` picks the
    /// lowest-numbered voice carrying a chord or rest at that tick — on the CANONICAL staff when the mark
    /// belongs to no staff at all. That emitted `VoiceElementID` is therefore narrower than the mark's real
    /// address, and the identity-matching overload above misses whenever the caller holds a different — equally
    /// correct — name for the same beat. Both misses it documents are of that shape.
    ///
    /// So this resolves BOTH sides to a beat and compares those. Neither side re-derives the arithmetic: the
    /// caller's anchor and the emitted anchor go through the same `SystemLaneSlot.position(of:in:)` the writer
    /// used, which reaches `Score.onset(of:)` — the one walker that folds `.locationShift` jogs and
    /// `effectiveMeasureDurations` in, and the reason `ScoreTickPosition` exists. A `MeasurePosition` is a
    /// reduced fraction of the bar, so the comparison is independent of `division` and of which voice or staff
    /// each side counted in.
    ///
    /// Exact identity is still tried first, and not only as an optimization: it keeps the answer for an anchor
    /// that resolves exactly identical to the overload above, so adopting this can add matches but never move
    /// one.
    ///
    /// `score` must be the score `self` was laid out from. Passing a different one silently compares beats
    /// across two documents; nothing here can detect that.
    ///
    /// **The beat is relaxed; the STAFF is not.** A `LayoutMeasure`'s `elements` aggregate every staff in the
    /// bar, so a scan that dropped the staff would hand a caret on staff 1 the origin of staff 0's "solo" at
    /// the same beat — the same class of bug `lyricLineY`'s comment records. A staff text keeps its anchor's
    /// staff; a system text deliberately does not, because it has none and is laid out on the canonical staff
    /// whatever staff the caller is editing from. That single exception IS miss 2.
    ///
    /// **What still returns `nil`:** a mark at a beat no chord or rest starts (a `<location>`-shifted lane
    /// element — the v1 limit `SystemLaneSlot` records), an anchor naming a non-timed element, and an anchor
    /// whose bar this document does not lay out.
    public func staffTextOrigin(
        at anchor: VoiceElementID,
        style: TextStyleType,
        in score: Score,
    ) -> CGPoint? {
        if let exact = staffTextOrigin(at: anchor, style: style) { return exact }
        guard let wanted = SystemLaneSlot.position(of: anchor, in: score) else { return nil }
        return firstOrigin(inMeasure: anchor.measureIndex) { element in
            guard case let .staffText(_, origin, _, candidateStyle, candidateAnchor, _) = element,
                  candidateStyle == style,
                  let candidateAnchor,
                  candidateAnchor.measureIndex == anchor.measureIndex,
                  style == .systemText || candidateAnchor.staff == anchor.staff,
                  SystemLaneSlot.position(of: candidateAnchor, in: score) == wanted
            else { return nil }
            return origin
        }
    }

    /// The final document-space leading origin of the chord symbol on the chord or rest at `anchor`.
    ///
    /// Identity-matched for `staffTextOrigin(at:style:)`'s reason. `LayoutHarmony.anchor` names the element the
    /// symbol is written against, which is the same `VoiceElementID` `SetChordSymbol` takes.
    public func harmonyOrigin(
        at anchor: VoiceElementID,
    ) -> CGPoint? {
        firstOrigin(inMeasure: anchor.measureIndex) { element in
            guard case let .harmony(harmony) = element,
                  harmony.anchor == anchor
            else { return nil }
            return CGPoint(
                x: CGFloat(harmony.anchorX),
                y: CGFloat(harmony.y),
            )
        }
    }

    /// The final document-space origin of the rehearsal-mark text itself.
    ///
    /// A rehearsal mark's layout origin belongs to its frame. The renderer moves the bottom-leading text origin
    /// inward by the frame padding, so this accessor applies that same offset for an inline editing caret.
    ///
    /// The two `measureIndex` checks below are not redundant in intent, though they are in effect today. The
    /// outer `where` narrows the scan to one bar's layout measures and is load-bearing: **do not remove it.**
    /// The inner one asks the mark itself which bar it is for, so the lookup does not depend on the fact that
    /// the engine currently files a mark under exactly the bar it was emitted for — one wiring point passes the
    /// same `measureIdx` to both, so the second check is a tautology at present and is here to stay true if
    /// that ever stops holding.
    public func rehearsalMarkTextOrigin(
        at anchor: VoiceElementID,
    ) -> CGPoint? {
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == anchor.measureIndex
            {
                for element in measure.elements {
                    guard case let .rehearsalMark(_, origin, _, _, candidateMeasureIndex, _) = element,
                          candidateMeasureIndex == anchor.measureIndex
                    else { continue }
                    let padding = RehearsalMarkFrame.paddingSp(sp: system.sp)
                    return absolute(
                        CGPoint(
                            x: origin.x + padding,
                            y: origin.y - padding,
                        ),
                        in: system,
                        measure: measure,
                    )
                }
            }
        }
        return nil
    }

    /// The document-space origin of the first element of `measureIndex` that `origin` answers for.
    ///
    /// Scoped to one bar because that is where a text-entry caret's anchor lives; systems are walked in order
    /// so a bar an unwound repeat laid out twice answers with its first copy.
    private func firstOrigin(
        inMeasure measureIndex: Int,
        origin: (LayoutElement) -> CGPoint?,
    ) -> CGPoint? {
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == measureIndex
            {
                for element in measure.elements {
                    guard let local = origin(element) else { continue }
                    return absolute(local, in: system, measure: measure)
                }
            }
        }
        return nil
    }

    private func absolute(
        _ origin: CGPoint,
        in system: LayoutSystem,
        measure: LayoutMeasure,
    ) -> CGPoint {
        CGPoint(
            x: system.origin.x + measure.origin.x + origin.x,
            y: system.origin.y + measure.origin.y + origin.y,
        )
    }
}
