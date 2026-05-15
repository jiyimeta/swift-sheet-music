// swiftlint:disable file_length
import Foundation
import SheetMusicCore
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
        // before the next ordinary chord in this voice. Cleared
        // whenever attached to the next main `Chord`. Stranded
        // entries (left over at end-of-voice) are dropped — MuseScore
        // doesn't play them either.
        var pendingGracesBefore: [GraceChord] = []
        // Measure-relative position of the next chord/rest, in
        // fractions-of-whole-note. Advances by each chord/rest's
        // tuplet-scaled duration. Used to compute `MeasurePosition`
        // for lifted system elements.
        var cursor = Fraction(numerator: 0, denominator: 1)
        // Accumulated `<location>` deltas that haven't yet attached
        // to an element. Each location shifts the next non-temporal
        // element by `delta` from the natural cursor. When the next
        // element is a system-level one (tempo / rehearsal / staff /
        // system text / swing) the shift is consumed by its
        // `MeasurePosition` and dropped from the voice stream;
        // otherwise the shift is emitted as a `.locationShift`
        // immediately before the next voice element so downstream
        // consumers (dynamic placement, …) keep seeing it.
        var pendingShift = Fraction(numerator: 0, denominator: 1)
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
            let position = MeasurePosition(offset: cursor + pendingShift)
            systemElements.append(PositionedSystemElement(
                position: position,
                element: element,
            ))
            pendingShift = Fraction(numerator: 0, denominator: 1)
        }
        for child in voiceChildren {
            switch child.name {
            case "Chord":
                if let graceType = Chord.graceType(in: child) {
                    // Decode shape but do NOT scale by tuplet ratios:
                    // graces don't consume tuplet time — see
                    // CompatMidiRender::renderGraceNotesBefore.
                    let inner = try Chord.decode(child)
                    let g = GraceChord(
                        graceType: graceType,
                        duration: inner.duration,
                        notes: inner.notes,
                    )
                    if graceType.isAfter {
                        // Attach to the most recently emitted chord.
                        // Walk backwards because dynamic / location
                        // elements may sit between the grace and its
                        // parent chord.
                        for i in stride(from: elements.count - 1, through: 0, by: -1) {
                            if case var .chord(parent) = elements[i] {
                                parent.graceNotesAfter.append(g)
                                elements[i] = .chord(parent)
                                break
                            }
                        }
                        // No preceding chord → drop silently.
                    } else {
                        pendingGracesBefore.append(g)
                    }
                    continue
                }
                var chord = try Chord.decode(child)
                chord.duration = scaled(
                    chord.duration, by: tupletFractions(),
                )
                if !pendingGracesBefore.isEmpty {
                    chord.graceNotesBefore = pendingGracesBefore
                    pendingGracesBefore.removeAll(keepingCapacity: true)
                }
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
                appendVoiceElement(.chord(rest))
                if case .measure = rest.duration {
                    // Same reasoning as the .Chord arm above.
                } else {
                    cursor += rest.duration.asFraction
                }
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
                appendVoiceElement(.fermata(Fermata(subtype: subtype, timeStretch: stretch)))
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
            case "RehearsalMark":
                try lifted(.rehearsalMark(
                    RehearsalMark.decode(child),
                ))
            case "location":
                // Voice-level cursor shift. MuseScore uses
                // `<location><fractions>N/D</fractions></location>`
                // to attach the next non-temporal element at a tick
                // that doesn't fall on a chord boundary. The shift
                // is relative to the current cursor; negative values
                // jog backwards. `<measures>` only appears in
                // spanner contexts and is ignored here.
                if let fracText = child.first("fractions")?.text,
                   let frac = Fraction(mscxString: fracText)
                {
                    pendingShift += frac
                }
            default:
                // Unknown elements are silently ignored. Decoder is permissive on purpose
                // — once we see what features individual MIDI tests actually need, they
                // can be promoted to first-class VoiceElement cases.
                continue
            }
        }
        // Stranded `pendingGracesBefore` (no following chord in this
        // voice) intentionally dropped — see comment on the buffer.
        // A trailing `pendingShift` with no following element has no
        // semantic effect and is discarded.
        return DecodeResult(
            voice: Voice(elements: elements, tuplets: tuplets),
            systemElements: systemElements,
        )
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
