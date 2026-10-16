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

    init(
        measureIndex: Int, staffCount: Int, options: MusicXMLImportOptions, partIndex: Int,
        registry: MusicXMLTempoRegistryBox,
    ) {
        builders = (0 ..< staffCount).map { _ in StaffMeasureBuilder() }
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
        let decoded = try MusicXMLNoteDecoder.decodeNote(
            node: child,
            divisions: divisions,
            existingVoiceElements: existing,
            drumTable: drumTable,
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
            let duration = positiveDuration(child, divisions: divisions) ?? .zeroTick
            let start = state.clock.now
            for element in elements {
                state.builders[staffIdx].append(element, toVoice: voice, start: start, end: start + duration)
            }
            state.clock.advance(by: duration)
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

    /// One `<direction>`: navigation as before, and every other kind through `MusicXMLDirectionDecoder` at the
    /// clock — voice elements as events, texts and rehearsal marks into the lane of the direction's staff.
    static func decodeDirectionChild(
        _ child: XMLTreeNode, state: inout MusicXMLMeasureState, divisions: DivisionsContext,
    ) {
        // MuseScore attaches measure-level jumps/markers to the first staff only, matching the .mscx layout where
        // they live on `<Staff id="1">`'s `<Measure>`.
        let navigation = MusicXMLJumpDecoder.decode(child)
        if !state.builders.isEmpty {
            state.builders[0].addMarkers(navigation.markers)
            state.builders[0].addJumps(navigation.jumps)
        }
        let context = MusicXMLDirectionDecoder.Context(
            measure: state.measureIndex,
            staffCount: state.staffCount,
            now: state.clock.now,
            divisions: divisions,
            options: state.options,
            partIndex: state.partIndex,
            registry: state.registry,
        )
        let output = MusicXMLDirectionDecoder.decode(child, context: context)
        state.directionEvents += output.events
        for placed in output.systemElements where state.builders.indices.contains(placed.staff) {
            state.builders[placed.staff].addSystemElement(placed.element, at: placed.position)
        }
        state.tempoElements += output.tempoElements
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
