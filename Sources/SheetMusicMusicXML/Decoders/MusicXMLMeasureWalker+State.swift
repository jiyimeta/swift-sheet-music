import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// What the walk of one `<measure>` carries from child to child: a builder per staff, the measure clock
/// (MuseScore's `mTime`) and the direction events decoded so far.
struct MusicXMLMeasureState {
    var builders: [StaffMeasureBuilder]
    var clock = MusicXMLMeasureClock()
    let measureIndex: Int
    let staffCount: Int
    var directionEvents: [MusicXMLDirectionEvent] = []
    /// The import's options, which the direction decoder reads (text-type inference).
    let options: MusicXMLImportOptions
    /// The part's index in the score.
    let partIndex: Int
    /// The import's tempo markings so far, shared by every part.
    let registry: MusicXMLTempoRegistryBox
    /// The measure's tempo markings, which go to the score's top staff.
    var tempoElements: [PositionedSystemElement] = []
    /// The `tempo` of the last `<sound>` standing directly in the measure, waiting for the next `<note>`
    /// (MuseScore's `tempoString`, `P2:2894-2896`).
    var pendingSoundTempo = ""
    /// The part's octave shifts and this measure's part-absolute start, which a note's shift is looked up at.
    var octaveShifts = MusicXMLOctaveShiftTable()
    var measureStart = Fraction.zeroTick
    /// Where the last chord or rest that took time started (MuseScore's `prevTime`, `P2:2858`): a `<chord/>` tone
    /// takes its octave shift there (`P2:7183`).
    var chordStart = Fraction.zeroTick
    /// The part's inferred lines so far, which the walk hands from measure to measure, and where this measure starts
    /// by the lengths the walk has recorded.
    var inferredLines = MusicXMLInferredLineLog()
    var partTick = Fraction.zeroTick
    /// The bar already holds a coda or To Coda (`handleRepeats`' `measureHasCoda`, which each measure starts without).
    var measureHasCoda = false
    /// The part's markers and jumps so far, which the walk hands from measure to measure and places after it.
    var repeats = MusicXMLRepeatLog()
    /// The program that wrote the file.
    let software: MusicXMLExporterSoftware
    /// How many direction events the part's earlier measures made, which this measure's events are numbered after.
    var eventBase = 0
    /// The part's delayed Sibelius ottava stop and the moves made so far, handed from measure to measure.
    var delayedOttavas = MusicXMLDelayedOttavaLog()
    /// The part is a vocal staff (`MusicXMLVocalStaff`).
    var isVocalStaff = false
    /// The key in force where the measure starts — before its notes, a `<key>` there included — which its written
    /// accidentals are judged against (`MusicXMLUserAccidentals`).
    var keyFifthsAtStart = 0

    init(
        measureIndex: Int, staffCount: Int, options: MusicXMLImportOptions, partIndex: Int,
        registry: MusicXMLTempoRegistryBox, software: MusicXMLExporterSoftware = .other,
    ) {
        builders = (0 ..< staffCount).map { _ in StaffMeasureBuilder() }
        self.software = software
        self.measureIndex = measureIndex
        self.staffCount = staffCount
        self.options = options
        self.partIndex = partIndex
        self.registry = registry
    }
}

extension MusicXMLMeasureWalker {
    /// One `<note>`: decoded into its staff's builder at the clock, which a new chord or rest then moves past
    /// (`P2:2842-2860` — a `<chord/>` tone and a grace note take no time).
    static func decodeNoteChild(
        _ child: XMLTreeNode,
        state: inout MusicXMLMeasureState,
        divisions: DivisionsContext,
        drumTable: MusicXMLDrumTable,
        glideTracker: inout MusicXMLGlideTracker,
    ) throws {
        let staffIdx = noteStaffIndex(child, staffCount: state.staffCount)
        let voice = child.first("voice")?.text ?? "1"
        state.builders[staffIdx].setDefaultVoice(voice)
        let existing = state.builders[staffIdx].elements(forVoice: voice)
        // A `<chord/>` tone starts where its chord did, every other note at the clock (`P2:7183`).
        let isChordTone = child.children.contains { $0.name == "chord" }
        let noteStart = isChordTone ? state.chordStart : state.clock.now
        endTempoLines(atFermataOf: child, staff: staffIdx, tick: noteStart, state: &state)
        let decoded = try MusicXMLNoteDecoder.decodeNote(
            node: child,
            divisions: divisions,
            existingVoiceElements: existing,
            drumTable: drumTable,
            octaveShift: state.octaveShifts.shift(staff: staffIdx, atTick: state.measureStart + noteStart),
        )
        switch decoded {
        case let .foldIntoLastChord(note, duration, trailingBreaths, articulations):
            state.builders[staffIdx].foldIntoLastChord(
                voice: voice,
                note: note,
                duration: duration,
                articulations: articulations,
            )
            // Breath marks / caesuras on a chord-folded note still belong after the host chord, which is the same
            // chord we just merged into.
            for breath in trailingBreaths {
                state.builders[staffIdx].append(.breath(breath), toVoice: voice)
            }
        case let .new(elements):
            let duration = timedDuration(child, elements: elements, divisions: divisions)
            // A tuplet this note stops short is padded with a rest, which the note follows (`P2:2848-2860`).
            let tuplet = MusicXMLTupletNote(node: child, divisions: divisions)
            if let tuplet {
                let now = state.clock.now
                state.clock.pad(by: state.builders[staffIdx].stopTuplet(before: tuplet, toVoice: voice, at: now))
            }
            let start = state.clock.now
            for element in elements {
                state.builders[staffIdx].append(element, toVoice: voice, start: start, end: start + duration)
            }
            state.builders[staffIdx].applyStem(MusicXMLStemBeam(node: child), toVoice: voice)
            if !duration.isZeroTick { state.chordStart = start }
            state.clock.advance(by: duration)
            if let tuplet {
                state.clock.pad(by: state.builders[staffIdx].joinTuplet(tuplet, toVoice: voice, end: start + duration))
            }
        case let .grace(note, shape, joinsChord, endsAfterGraces):
            state.builders[staffIdx].appendGrace(
                note, shape: shape, joinsChord: joinsChord, endsAfterGraces: endsAfterGraces, toVoice: voice,
            )
            // A grace note is not in the voice's elements yet, so the index below would name the chord before it;
            // glissandi from grace notes are not modelled.
            return
        }
        recordGlides(
            child,
            builder: state.builders[staffIdx],
            staffIdx: staffIdx,
            voice: voice,
            measureIndex: state.measureIndex,
            glideTracker: &glideTracker,
        )
    }

    /// Glissando / slide events on this note: record the chord's voice + index now (after append) so the post-walk
    /// pass can mutate the start chord in place. For fold-into-chord notes, the chord index didn't change —
    /// `count - 1` still points at the same chord.
    private static func recordGlides(
        _ child: XMLTreeNode,
        builder: StaffMeasureBuilder,
        staffIdx: Int,
        voice: String,
        measureIndex: Int,
        glideTracker: inout MusicXMLGlideTracker,
    ) {
        guard let voiceIdx = builder.voicePositionIndex(forVoice: voice) else { return }
        let chordIdx = builder.elements(forVoice: voice).count - 1
        guard chordIdx >= 0 else { return }
        glideTracker.consume(
            noteNode: child,
            staffIndex: staffIdx,
            measureIndex: measureIndex,
            voiceIndex: voiceIdx,
            chordElementIndex: chordIdx,
        )
    }

    /// One `<direction>`: its one repeat into the part's repeat log at `tick + offset`, and every other kind through
    /// `MusicXMLDirectionDecoder` at the clock — voice elements as events, texts and rehearsal marks into the lane of
    /// the direction's staff.
    static func decodeDirectionChild(
        _ child: XMLTreeNode, state: inout MusicXMLMeasureState, divisions: DivisionsContext,
    ) {
        let context = MusicXMLDirectionDecoder.Context(
            measure: state.measureIndex,
            staffCount: state.staffCount,
            now: state.clock.now,
            divisions: divisions,
            options: state.options,
            partIndex: state.partIndex,
            measureStart: state.partTick,
            registry: state.registry,
            software: state.software,
            isVocalStaff: state.isVocalStaff,
        )
        let navigation = MusicXMLJumpDecoder.decode(child, measureHasCoda: &state.measureHasCoda)
        state.repeats.add(
            navigation, measure: state.measureIndex, tick: MusicXMLDirectionDecoder.tick(of: child, context: context),
            partTick: state.partTick,
        )
        let output = MusicXMLDirectionDecoder.decode(child, context: context)
        delayOttavaStops(output.events, now: context.now, state: &state)
        state.directionEvents += output.events
        // A direction's dynamics and tempo text end earlier lines before its own words start one (`P2:3700-3705`,
        // `3754-3764`).
        for terminator in output.lineTerminators {
            state.inferredLines.terminate(terminator)
        }
        for line in output.inferredLines {
            state.inferredLines.open(line)
        }
        for placed in output.systemElements where state.builders.indices.contains(placed.staff) {
            state.builders[placed.staff].addSystemElement(placed.element, at: placed.position)
        }
        state.tempoElements += output.tempoElements
    }

    /// A Sibelius ottava stop among a direction's events waits for the next note (`P2:3788-3794`): numbered by its
    /// place in the part's events, at the clock where it was read.
    private static func delayOttavaStops(
        _ events: [MusicXMLDirectionEvent], now: Fraction, state: inout MusicXMLMeasureState,
    ) {
        let base = state.eventBase + state.directionEvents.count
        for (offset, event) in events.enumerated() {
            guard case let .spannerStop(_, edit) = event.payload, case .delayedOttavaStop? = edit.change else {
                continue
            }
            state.delayedOttavas.delay(eventIndex: base + offset, absolute: state.partTick + now)
        }
    }

    /// Before a `<note>`: a delayed ottava stop read before the clock moves here (`P2:2835-2839`).
    static func moveDelayedOttavaStop(state: inout MusicXMLMeasureState) {
        let now = state.clock.now
        state.delayedOttavas.noteStarts(measure: state.measureIndex, tick: now, absolute: state.partTick + now)
    }

    /// A note's `<fermata>` ends the tempo lines inferred on its staff, at its chord's start (`P2:9472-9479`).
    private static func endTempoLines(
        atFermataOf note: XMLTreeNode, staff: Int, tick: Fraction, state: inout MusicXMLMeasureState,
    ) {
        guard note.all("notations").contains(where: { !$0.all("fermata").isEmpty }) else { return }
        state.inferredLines.terminate(
            kind: .tempo, staff: staff, atAbsolute: state.partTick + tick, measure: state.measureIndex, tick: tick,
        )
    }

    /// A `<barline>`: applied to every staff; a `<fermata>` in it ends the tempo lines inferred on the part's first
    /// staff, at the clock (`P2:5835-5860`). A bar line inside the measure goes into each staff's first voice at the
    /// clock (`addBarlineToMeasure`), placed among the notes as a direction is.
    static func decodeBarlineChild(_ child: XMLTreeNode, state: inout MusicXMLMeasureState) {
        let decoded = MusicXMLBarlineDecoder.decode(child)
        for staff in state.builders.indices {
            if decoded.placement == .middle, let line = decoded.inline {
                state.directionEvents.append(MusicXMLDirectionEvent(
                    measure: state.measureIndex, staff: staff, tick: state.clock.now, payload: .voice(.barLine(line)),
                ))
            } else {
                state.builders[staff].apply(barline: decoded)
            }
        }
        guard !child.all("fermata").isEmpty else { return }
        let now = state.clock.now
        state.inferredLines.terminate(
            kind: .tempo, staff: 0, atAbsolute: state.partTick + now, measure: state.measureIndex, tick: now,
        )
    }

    /// A `<sound>` directly in the measure: its `tempo` waits for the next `<note>`; each `<sound>` replaces it, one
    /// without a tempo clearing it (`P2:2894-2896`).
    static func decodeSoundChild(_ child: XMLTreeNode, state: inout MusicXMLMeasureState) {
        state.pendingSoundTempo = child.attributes["tempo"] ?? ""
    }

    /// Before a `<note>`: a waiting measure-level sound tempo becomes a hidden "♩ = N" at the clock, unless a marking
    /// there already blocks it, and stops waiting either way (`P2:2815-2833`).
    static func placePendingSoundTempo(state: inout MusicXMLMeasureState) {
        guard !state.pendingSoundTempo.isEmpty else { return }
        let printed = state.pendingSoundTempo
        state.pendingSoundTempo = ""
        let now = state.clock.now
        guard state.registry.registry.canAdd(measure: state.measureIndex, tick: now) else { return }
        // `String::toDouble` reads a malformed tempo as 0, which `setTempo` clamps to its floor.
        let tempo = MusicXMLDirectionDecoder.hiddenTempo(printedTempo: printed, quarterBPM: Double(printed) ?? 0)
        state.tempoElements.append(PositionedSystemElement(
            position: MeasurePosition(offset: now), element: .tempo(tempo),
        ))
        state.registry.registry.record(measure: state.measureIndex, tick: now, beatsPerSecond: tempo.beatsPerSecond)
    }

    /// `<forward>` and `<backup>` move the clock by their `<duration>` (`P2:2862-2887`); one without a positive
    /// `<duration>` does nothing (`MusicXmlParserPass2::duration`).
    static func moveClock(_ child: XMLTreeNode, state: inout MusicXMLMeasureState, divisions: DivisionsContext) {
        guard let duration = positiveDuration(child, divisions: divisions) else { return }
        if child.name == "forward" {
            state.clock.forward(by: duration)
        } else {
            state.clock.backup(by: duration, divisionsPerQuarter: divisions.perQuarter)
        }
    }

    /// The part's length for the measure (`P1:2833-2878`), which the spanners' `<next>` offsets roll over and the
    /// score's measure takes the longest of: how far its clock reached, a tuplet's padding included; for an empty
    /// measure, the last `<time>`'s `beats / beat-type`, or 4/4 when there is none. A length that is no whole number
    /// of 128ths rounds up to the next one, or down when it passes one by less than a division (MuseScore keeps a
    /// measure to whole 128ths).
    static func measureLength(
        _ state: MusicXMLMeasureState, attributes: MusicXMLAttributesSnapshot, divisions: DivisionsContext,
    ) -> Fraction {
        let reach = state.clock.reach
        guard !reach.isZeroTick else { return nominalLength(attributes) ?? Fraction(numerator: 4, denominator: 4) }
        let in128ths = Fraction(numerator: reach.numerator * 128, denominator: reach.denominator)
        guard in128ths.denominator != 1 else { return reach }
        let whole = in128ths.numerator / in128ths.denominator
        let down = Fraction(numerator: whole, denominator: 128)
        let past = reach - down
        if divisions.perQuarter > 0, past.precedes(Fraction(numerator: 1, denominator: 4 * divisions.perQuarter)) {
            return down
        }
        return Fraction(numerator: whole + 1, denominator: 128)
    }

    /// The last `<time>`'s `beats / beat-type`, the length MuseScore gives the measure's time signature; nil before
    /// any `<time>`.
    static func nominalLength(_ attributes: MusicXMLAttributesSnapshot) -> Fraction? {
        guard let beats = attributes.timeN, let beatType = attributes.timeD, beats > 0, beatType > 0 else { return nil }
        return Fraction(numerator: beats, denominator: beatType)
    }

    /// How far a chord or rest moves the clock: its value as the note decoder read it, which is MuseScore's
    /// `checkTiming` — `<type>`, dots and `<time-modification>` before `<duration>` (`P2:7091-7094`). A whole rest
    /// takes its `<duration>`, as Sibelius writes a measure rest so, and a measure rest, which has no value of its own,
    /// does too.
    private static func timedDuration(
        _ node: XMLTreeNode, elements: [VoiceElement], divisions: DivisionsContext,
    ) -> Fraction {
        let specified = positiveDuration(node, divisions: divisions)
        let value = elements.lazy.compactMap { element -> NoteDuration? in
            if case let .chord(chord) = element { chord.duration } else { nil }
        }.first
        let isWholeRest = node.children.contains { $0.name == "rest" } && node.first("type")?.text == "whole"
        guard let value, value != .measure, !isWholeRest || specified == nil else { return specified ?? .zeroTick }
        return value.asFraction
    }

    /// The node's `<duration>` as a fraction of a whole note, when it is a positive integer.
    private static func positiveDuration(_ node: XMLTreeNode, divisions: DivisionsContext) -> Fraction? {
        guard let text = node.first("duration")?.text, let value = Int(text), value > 0, divisions.perQuarter > 0
        else { return nil }
        return divisions.fractionOfWhole(value)
    }

    /// Read `<note><staff>N</staff>` and convert to a 0-based staff index. Defaults to 0 when absent or out of range.
    static func noteStaffIndex(_ note: XMLTreeNode, staffCount: Int) -> Int {
        guard let text = note.first("staff")?.text, let n = Int(text), n >= 1 else {
            return 0
        }
        return min(n - 1, staffCount - 1)
    }
}
