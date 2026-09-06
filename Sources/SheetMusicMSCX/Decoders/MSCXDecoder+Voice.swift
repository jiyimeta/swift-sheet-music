import SheetMusicCore

// swiftlint:disable file_length
import SheetMusicFoundation
import SheetMusicXMLTools

extension Voice {
    /// Decoded voice plus any system-level elements (tempo,
    /// rehearsal mark, system/staff text, swing) that were lifted
    /// out of the voice during decoding. Each lifted element carries
    /// its measure-relative `MeasurePosition` so the caller can
    /// merge it into the owning `SystemMeasure`.
    struct DecodeResult {
        let voice: Voice
        let systemElements: [PositionedSystemElement]

        /// Passthrough to the underlying `Voice.elements` so tests
        /// and other consumers that only care about voice-bound
        /// content don't have to thread `.voice` through.
        var elements: [VoiceElement] {
            voice.elements
        }

        var tuplets: [Tuplet] {
            voice.tuplets
        }
    }

    /// Convenience that drops the lifted system elements, returning
    /// just the voice. Callers that don't track score-level system
    /// content (most tests, ad-hoc inspections) use this; the full
    /// `DecodeResult` is reserved for paths that wire system
    /// elements into `Score.systemMeasures`.
    static func decode(_ node: XMLTreeNode) throws -> Voice {
        try decodeWithSystemElements(node).voice
    }

    private struct OpenTuplet {
        let ratio: Fraction
        let firstElementIndex: Int
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func decodeWithSystemElements(
        _ node: XMLTreeNode,
    ) throws -> DecodeResult {
        let voiceChildren = injectMS2EndTuplets(node.children)
        var elements: [VoiceElement] = []
        elements.reserveCapacity(voiceChildren.count)
        var tuplets: [Tuplet] = []
        var systemElements: [PositionedSystemElement] = []
        // Stack of open tuplet ratios (normal/actual). Each <Tuplet>
        // pushes, each <endTuplet/> pops. Chord/Rest durations are
        // scaled by the product of every ratio on the stack — mirrors
        // MuseScore's positional state machine in
        // MeasureRead::readVoice. `firstElementIndex` records where
        // the tuplet's first member landed so we can finalise a
        // `Tuplet` range at `<endTuplet>`.
        var tupletStack: [OpenTuplet] = []
        // Buffer for `<Chord><acciaccatura/>...` etc. encountered
        // before the next ordinary chord in this voice — every
        // grace-type chord, after-graces included, since MuseScore
        // writes the two types into one run ahead of their shared
        // parent (`MeasureRead::readVoice`,
        // `rw/read460/measureread.cpp:261-286`; see
        // `Chord.mscxFileOrderedGraces`). Cleared whenever attached to
        // the next main `Chord`, which is also where the run is split
        // by grace-type tag. Stranded entries (left over at
        // end-of-voice) are dropped — MuseScore's own buffer is
        // per-measure and never flushed, so it doesn't keep them
        // either.
        var pendingGraces: [GraceChord] = []
        // Measure-relative read position, in fractions-of-whole-note.
        // Advances by each chord/rest's tuplet-scaled duration AND by
        // every `<location>` delta, exactly like the single tick that
        // `ReadContext` carries: `setLocation` resolves a relative
        // `Location` against the context's *current* tick and stores
        // the result, so a jog stays in force for everything that
        // follows in the voice. Used to compute `MeasurePosition` for
        // lifted system elements.
        var cursor = Fraction(numerator: 0, denominator: 1)
        // The net `<location>` movement not yet written into the voice
        // stream. It is flushed as a `.locationShift` immediately
        // before the next voice element, so downstream consumers
        // (dynamic placement, playback, layout) walk the same cursor
        // the reader did. Lifted system elements (tempo / rehearsal /
        // staff / system text / swing) record their tick and leave
        // this alone — they mark a position, they do not consume the
        // jog — so the balanced back-then-forward pair MuseScore
        // writes around an off-beat mark nets to zero and adds nothing
        // to the voice. `cursor` has always already absorbed whatever
        // is sitting here; this tracks what still needs *writing out*,
        // never where the reader is.
        var pendingShift = Fraction(numerator: 0, denominator: 1)
        // `<Beam>` sits in the voice stream immediately before the group
        // it governs. MuseScore attaches the beam it just read to the
        // FIRST following ChordRest and clears the pending reference
        // (`rw/read410/measureread.cpp:263`), so we mirror that: the
        // flag lands on the next chord/rest and resets to the default.
        var pendingBeamVisible = true
        func takePendingBeamVisible() -> Bool {
            defer { pendingBeamVisible = true }
            return pendingBeamVisible
        }
        func tupletFractions() -> [Fraction] {
            tupletStack.map(\.ratio)
        }
        func appendVoiceElement(_ element: VoiceElement) {
            if pendingShift.numerator != 0 {
                elements.append(.locationShift(delta: pendingShift))
                pendingShift = Fraction(numerator: 0, denominator: 1)
            }
            elements.append(element)
        }
        func lifted(_ element: SystemElement) {
            let position = MeasurePosition(offset: cursor)
            systemElements.append(PositionedSystemElement(
                position: position,
                element: element,
            ))
            // `pendingShift` deliberately survives: a lifted element
            // records where it sits but does not *consume* the jog
            // that got there. The voice cursor stays moved for the
            // chords and rests that follow, so the shift still has to
            // reach the voice stream. Balanced jog pairs (the shape
            // MuseScore writes around an off-beat mark) cancel here
            // and emit nothing, which is why the common case adds no
            // `.locationShift` at all.
        }
        for child in voiceChildren {
            switch child.name {
            case "Chord":
                if let graceType = Chord.graceType(in: child) {
                    // Decode shape but do NOT scale by tuplet ratios:
                    // graces don't consume tuplet time — see
                    // CompatMidiRender::renderGraceNotesBefore.
                    let inner = try Chord.decode(child)
                    // `GraceChord` carries no spanner list, so a slur that
                    // *begins* on a grace note cannot be modeled. Its `<prev>`
                    // end marker is consumed in silence by design, so without
                    // this the whole pair would vanish untraced — MuseScore's
                    // own `selectionfilter_gracesandslurs.mscx` writes exactly
                    // this shape. One diagnostic per grace chord, naming the
                    // types it carried.
                    if !inner.spanners.isEmpty {
                        let types = Set(inner.spanners.map(\.rawType))
                            .sorted()
                            .joined(separator: "/")
                        mscxDecoderWarn(
                            code: "mscx.chord.spannerDropped",
                            message: "grace-note <Spanner type=\"\(types)\"> "
                                + "is not modeled — dropped",
                            location: "Chord[grace]/Spanner",
                        )
                    }
                    // `GraceChord` carries no bracket either, and unlike a
                    // spanner a `<ChordBracket>` is *consumable*: `Chord.decode`
                    // lifts it out of `inner.preservedMarkup` into
                    // `inner.bracket`, which this initializer then drops. Put
                    // the source subtree back so the element still round-trips,
                    // exactly as it did before `<ChordBracket>` was modeled.
                    // It lands after the other preserved children rather than
                    // in document order; MuseScore's reader is order-agnostic
                    // inside `<Chord>`.
                    let graceMarkup = inner.preservedMarkup
                        + child.all("ChordBracket").map(PreservedXML.init)
                    pendingGraces.append(GraceChord(
                        graceType: graceType,
                        duration: inner.duration,
                        notes: inner.notes,
                        preservedMarkup: graceMarkup,
                    ))
                    continue
                }
                var chord = try Chord.decode(child)
                chord.duration = scaled(
                    chord.duration, by: tupletFractions(),
                )
                if !pendingGraces.isEmpty {
                    // Split the buffered run by grace-type tag, exactly
                    // as `Chord::graceNotesBefore()` / `graceNotesAfter()`
                    // split MuseScore's single `m_graceNotes` vector —
                    // the before side forward, the after side reversed.
                    // See `Chord.mscxFileOrderedGraces` for the citation
                    // trail, including the upstream playback test that
                    // pins the after-run's reversal.
                    chord.graceNotesBefore = pendingGraces
                        .filter { !$0.graceType.isAfter }
                    chord.graceNotesAfter = Array(
                        pendingGraces
                            .filter(\.graceType.isAfter)
                            .reversed(),
                    )
                    pendingGraces.removeAll(keepingCapacity: true)
                }
                chord.beamVisible = takePendingBeamVisible()
                appendVoiceElement(.chord(chord))
                // `.measure` chords carry no intrinsic duration; the
                // measure-rest fills the bar by definition, so any
                // following element would be malformed. Skip the
                // cursor advance instead of trapping in `asFraction`.
                if case .measure = chord.duration {
                    // no-op; cursor stays put
                } else {
                    cursor += chord.duration.asFraction
                }
            case "Rest":
                var rest = try MSCXRestDecoder.decode(child)
                rest.duration = scaled(
                    rest.duration, by: tupletFractions(),
                )
                rest.beamVisible = takePendingBeamVisible()
                appendVoiceElement(.chord(rest))
                if case .measure = rest.duration {
                    // A measure rest's `NoteDuration` is the bare
                    // `.measure` marker (its fraction is resolved
                    // against the bar later), but the rest still
                    // occupies the whole bar. Advance the positioning
                    // cursor by the rest's *written* `<duration>` so a
                    // following `<location>` / lifted system element
                    // (e.g. a `<Tempo>` near the bar end) is placed
                    // relative to the bar END, matching MuseScore's
                    // write cursor. Without this a backward
                    // `<location>` after a full-measure rest underflows
                    // to a negative tick and trips `MidiWriter`'s
                    // "events must be sorted by tick" precondition.
                    if let durText = child.first("duration")?.text,
                       let durFrac = Fraction(mscxString: durText)
                    {
                        cursor += durFrac
                    }
                } else {
                    cursor += rest.duration.asFraction
                }
            case "Beam":
                // `<visible>` still feeds the modeled flag on the next
                // chord/rest, but the whole node also stays in the
                // ordered stream so unmodeled `<l1>` / `<l2>` stem
                // positions survive. The encoder suppresses its
                // synthesized hidden Beam when this preserved one is
                // immediately before that chord/rest.
                pendingBeamVisible =
                    (child.first("visible")?.text ?? "1") != "0"
                appendVoiceElement(.preserved(PreservedXML(child)))
            case "Tuplet":
                if let ratio = tupletRatio(from: child) {
                    tupletStack.append(OpenTuplet(
                        ratio: ratio,
                        firstElementIndex: elements.count,
                    ))
                }
            case "endTuplet":
                if let top = tupletStack.popLast() {
                    let endIndex = elements.count - 1
                    if endIndex >= top.firstElementIndex {
                        tuplets.append(Tuplet(
                            normalNotes: top.ratio.numerator,
                            actualNotes: top.ratio.denominator,
                            startIndex: top.firstElementIndex,
                            endIndex: endIndex,
                        ))
                    }
                }
            case "KeySig":
                try appendVoiceElement(.keySignature(KeySignature.decode(child)))
            case "TimeSig":
                try appendVoiceElement(.timeSignature(TimeSignature.decode(child)))
            case "Clef":
                try appendVoiceElement(.clef(Clef.decode(child)))
            case "BarLine":
                try appendVoiceElement(.barLine(BarLine.decode(child)))
            case "Tempo":
                try lifted(.tempo(Tempo.decode(child)))
            case "Dynamic":
                try appendVoiceElement(.dynamic(Dynamic.decode(child)))
            case "Spanner":
                try appendVoiceElement(.spanner(Spanner.decode(child)))
            case "MeasureRepeat", "RepeatMeasure":
                // <RepeatMeasure> is the MuseScore 3.x spelling of the same
                // element (see MeasureRead::readVoice in measureread.cpp:336).
                try appendVoiceElement(.measureRepeat(MeasureRepeat.decode(child)))
            case "Fermata":
                let subtype = child.first("subtype")?.text ?? ""
                let stretch: Double? = child.first("timeStretch").flatMap { Double($0.text) }
                var fermata = Fermata(subtype: subtype, timeStretch: stretch)
                fermata.elementProperties = ElementProperties(decodingMSCXChildrenOf: child)
                appendVoiceElement(.fermata(fermata))
            case "Breath":
                appendVoiceElement(.breath(Breath.decodeMSCX(child)))
            case "StaffText":
                if Swing.isSwingMarker(child) {
                    lifted(.swing(
                        Swing.decode(child, isSystemText: false),
                    ))
                } else {
                    try lifted(.staffText(
                        StaffText.decode(child, isSystemText: false),
                    ))
                }
            case "SystemText":
                if Swing.isSwingMarker(child) {
                    lifted(.swing(
                        Swing.decode(child, isSystemText: true),
                    ))
                } else {
                    try lifted(.staffText(
                        StaffText.decode(child, isSystemText: true),
                    ))
                }
            case "Harmony":
                try appendVoiceElement(.harmony(Harmony.decode(child)))
            case "Sticking":
                appendVoiceElement(.sticking(Sticking.decode(child)))
            case "Expression":
                appendVoiceElement(.expression(ExpressionText.decode(child)))
            case "RehearsalMark":
                try lifted(.rehearsalMark(
                    RehearsalMark.decode(child),
                ))
            case "InstrumentChange":
                try lifted(.instrumentChange(
                    InstrumentChange.decode(child),
                ))
            case "location":
                // Voice-level cursor shift. MuseScore uses
                // `<location><fractions>N/D</fractions></location>`
                // to attach the next non-temporal element at a tick
                // that doesn't fall on a chord boundary. The shift
                // is relative to the current cursor; negative values
                // jog backwards. `<measures>` only appears in
                // spanner contexts and is ignored here.
                //
                // Move `cursor`, not just `pendingShift`: MuseScore
                // keeps one tick (`ReadContext::setLocation` →
                // `Location::toAbsolute` against the current
                // location), so consecutive `<location>`s ACCUMULATE.
                // A bar with two off-beat tempo marks is written as
                // jog-back, `<Tempo>`, jog-forward, `<Tempo>`, and the
                // second jog starts from where the first one left the
                // cursor — not from the chord/rest boundary.
                if let fracText = child.first("fractions")?.text,
                   let frac = Fraction(mscxString: fracText)
                {
                    cursor += frac
                    pendingShift += frac
                }
            default:
                guard !PreservedMarkupPolicy.neverPreserved.contains(child.name)
                else { continue }
                // `appendVoiceElement` deliberately flushes a pending
                // `.locationShift` first. A preserved child marks a
                // position in the voice stream, so the jog must precede
                // it; leaving the jog pending until the next modeled
                // element would move the preserved child to the wrong
                // tick on re-encode.
                appendVoiceElement(.preserved(PreservedXML(child)))
            }
        }
        // Stranded `pendingGraces` (no following chord in this
        // voice) intentionally dropped — see comment on the buffer.
        // A trailing `pendingShift` with no following element has no
        // semantic effect and is discarded.
        try resolveTremoloPairs(in: &elements)
        return DecodeResult(
            voice: Voice(elements: elements, tuplets: tuplets),
            systemElements: systemElements,
        )
    }

    /// Second pass over the decoded `elements`: every chord whose
    /// first-pass tremolo carries `.between` is the *start* of a
    /// two-chord (`c8` / `c16` / `c32`) tremolo. MuseScore writes the
    /// same `<Tremolo>` element on both members of the pair, so the
    /// follower's redundant copy must be cleared here — otherwise the
    /// follower would render its own beams and the MIDI / playback
    /// passes would double-count the tremolo.
    ///
    /// The follower is the next `.chord` in voice order. Non-chord
    /// elements (dynamics, location shifts, …) are skipped defensively;
    /// MuseScore never interposes rests between paired chords, but the
    /// loop is written to tolerate it. A start with no follower is a
    /// malformed score and throws.
    private static func resolveTremoloPairs(
        in elements: inout [VoiceElement],
    ) throws {
        for i in elements.indices {
            guard case let .chord(start) = elements[i],
                  let trem = start.tremolo,
                  trem.span == .between
            else { continue }
            var followerIndex: Int?
            for j in (i + 1) ..< elements.count {
                if case .chord = elements[j] {
                    followerIndex = j
                    break
                }
            }
            guard let fIdx = followerIndex,
                  case var .chord(follower) = elements[fIdx]
            else {
                throw SheetMusicError.malformedScore(
                    ScoreFault(
                        code: "mscx.tremolo.missingFollower",
                        message: "Two-note tremolo at element \(i) has no follower chord",
                        location: "element \(i)",
                    ),
                )
            }
            follower.tremolo = nil
            elements[fIdx] = .chord(follower)
        }
    }

    /// Pre-process voice children so MS2 tuplet bookkeeping looks like
    /// MS3+ to the main decoder loop. MS2 marks each tuplet member
    /// chord with `<Tuplet>N</Tuplet>` referring to a preceding
    /// `<Tuplet id="N">` declaration, and writes no `<endTuplet/>`
    /// — the tuplet ends implicitly when a chord stops carrying the
    /// id. The MS3+ stack-based path in `decodeWithSystemElements`
    /// keeps each declared `<Tuplet>` open until it sees
    /// `<endTuplet/>`, so an MS2 voice with one triplet followed by
    /// straight quarters would scale every later chord by 2/3 and
    /// shrink the rest of the bar.
    ///
    /// Inject a synthetic `<endTuplet/>` immediately before the first
    /// chord that doesn't carry the open tuplet's id (and at end of
    /// voice for any tuplets still open). MS3+ inputs are untouched
    /// because their `<Tuplet>` declarations carry no `id` attribute
    /// and their chords carry no `<Tuplet>` child, so `openIds`
    /// remains empty throughout.
    ///
    /// Mirrors MuseScore 2 `libmscore/measure.cpp` `Measure::readVoice`
    /// where each chord's `tuplet()` pointer is looked up by the
    /// referenced id.
    private static func injectMS2EndTuplets(_ children: [XMLTreeNode]) -> [XMLTreeNode] {
        var openIds: [Int] = []
        var result: [XMLTreeNode] = []
        result.reserveCapacity(children.count + 4)
        for child in children {
            switch child.name {
            case "Tuplet":
                if let idStr = child.attributes["id"], let id = Int(idStr) {
                    // MS2 emits no <endTuplet/>: a new sibling
                    // `<Tuplet id="…">` is itself the implicit close
                    // of any previous still-open MS2 tuplet. The
                    // optional `<parent>X</parent>` child (used for
                    // genuinely-nested tuplets) names the ancestor
                    // that should stay open; everything between it
                    // and the top is closed. C++: MuseScore 2
                    // `libmscore/tuplet.cpp` `Tuplet::read`.
                    let parent: Int? = {
                        guard let raw = child.first("parent")?.text else { return nil }
                        return Int(raw)
                    }()
                    while let top = openIds.last, top != parent {
                        result.append(XMLTreeNode(name: "endTuplet"))
                        openIds.removeLast()
                    }
                    openIds.append(id)
                }
                result.append(child)
            case "Chord", "Rest":
                let referenced: Int? = {
                    guard let raw = child.first("Tuplet")?.text else { return nil }
                    return Int(raw)
                }()
                while let top = openIds.last, referenced != top {
                    result.append(XMLTreeNode(name: "endTuplet"))
                    openIds.removeLast()
                }
                result.append(child)
            default:
                result.append(child)
            }
        }
        while !openIds.isEmpty {
            result.append(XMLTreeNode(name: "endTuplet"))
            openIds.removeLast()
        }
        return result
    }

    /// Parse a `<Tuplet>` element's ratio (normalNotes/actualNotes). A triplet's
    /// 3 notes occupy the time of 2 normal notes, so the scale is 2/3.
    private static func tupletRatio(from node: XMLTreeNode) -> Fraction? {
        guard let normalText = node.first("normalNotes")?.text,
              let actualText = node.first("actualNotes")?.text,
              let normal = Int(normalText),
              let actual = Int(actualText),
              normal > 0, actual > 0
        else {
            return nil
        }
        return Fraction(numerator: normal, denominator: actual)
    }

    private static func scaled(_ duration: NoteDuration, by tupletStack: [Fraction]) -> NoteDuration {
        guard !tupletStack.isEmpty else { return duration }
        // `.measure` rests cannot be inside a tuplet (they fill a
        // whole bar); defensively pass through unchanged so we don't
        // trap in `asFraction`.
        if case .measure = duration { return duration }
        var frac = duration.asFraction
        for ratio in tupletStack {
            frac = Fraction(
                numerator: frac.numerator * ratio.numerator,
                denominator: frac.denominator * ratio.denominator,
            )
        }
        return .fraction(frac)
    }
}
