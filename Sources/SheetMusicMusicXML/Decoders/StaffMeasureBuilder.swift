import SheetMusicCore
import SheetMusicFoundation

/// Accumulator for one staff's measure. Collects per-voice element buckets
/// where the "voice" key is an MSCX-style index derived from first-seen
/// MusicXML voice ids. MusicXML assigns global voice ids within a part
/// (e.g. 1 for right hand, 5 for left hand); MSCX uses positional voices
/// per `<voice>` block inside a measure. When a staff has only one MusicXML
/// voice id, everything — including attributes and barlines — ends up in a
/// single MSCX voice. Attributes always land in the first voice index.
struct StaffMeasureBuilder {
    private var voiceIndex: [String: Int] = [:]
    private var voices: [[VoiceElement]] = []
    /// Where each voice's chords and rests sit by the measure clock, parallel to `voices`.
    private var anchors: [[MusicXMLChordAnchor]] = []
    private var defaultVoiceId: String?
    private var startRepeat = false
    private var endRepeatCount: Int?
    private var trailingBarline: BarLine?
    /// System-level elements lifted out during decode (rehearsal
    /// marks and the texts a direction's words make). The caller pulls these
    /// out via `build()` and merges them into `Score.systemMeasures`.
    /// `originalStaff` is left nil here and stamped by the caller
    /// once the staff address is known.
    private var systemElements: [PositionedSystemElement] = []
    /// Grace chords waiting for the chord they lean on, per positional voice, in document order — MuseScore's
    /// `GraceChordList` (`importmusicxmlpass2.cpp`), kept per voice where MuseScore keeps one per measure and leaves
    /// "check if same voice" as a TODO.
    private var pendingGraces: [Int: [GraceChord]] = [:]
    /// How many of a voice's pending grace chords end in a slur or wavy line and so lean back on the previous chord
    /// (MuseScore's `gac`).
    private var pendingAfterGraceCount: [Int: Int] = [:]

    /// Result of `build()`: the decoded `Measure` and the system
    /// elements that should be merged into the score-level
    /// `SystemMeasure` for this measure index.
    struct Built {
        let measure: Measure
        let systemElements: [PositionedSystemElement]
        /// Where positional voice 0's chords and rests sit by the measure clock (`MusicXMLChordAnchor`).
        let anchors: [MusicXMLChordAnchor]
    }

    /// Record a system-lane element (a staff text, a rehearsal mark, …) at `position` in this measure.
    mutating func addSystemElement(_ element: SystemElement, at position: MeasurePosition) {
        systemElements.append(PositionedSystemElement(position: position, element: element))
    }

    /// Append to the first voice index (MSCX attributes convention). Lazily
    /// creates the voice 0 bucket if no notes have been seen yet.
    mutating func appendAttribute(_ element: VoiceElement) {
        ensureFirstVoice()
        voices[0].append(element)
    }

    mutating func setDefaultVoice(_ voiceId: String) {
        defaultVoiceId = voiceId
    }

    /// Append a note-sourced element under the MSCX index corresponding to
    /// this MusicXML voice id. A chord takes the voice's pending grace chords: those a slur or wavy line ended on
    /// become after-graces of the chord before it, and the rest lead into this one (MuseScore's
    /// `addGraceChordsAfter` then `addGraceChordsBefore`). A chord given its clock window (`start`, `end`) records a
    /// `MusicXMLChordAnchor` at the index it is appended at.
    mutating func append(
        _ element: VoiceElement, toVoice voiceId: String, start: Fraction? = nil, end: Fraction? = nil,
    ) {
        let idx = internVoice(voiceId)
        if case .chord = element, let start, let end {
            anchors[idx].append(MusicXMLChordAnchor(elementIndex: voices[idx].count, start: start, end: end))
        }
        guard case var .chord(chord) = element, let pending = pendingGraces.removeValue(forKey: idx) else {
            voices[idx].append(element)
            return
        }
        let afterCount = min(pendingAfterGraceCount.removeValue(forKey: idx) ?? 0, pending.count)
        // With no chord before it in the voice the after-graces have nowhere to lean back on; MuseScore leaves them
        // pending, so they lead into this chord with the rest.
        let leading = attachBack(Array(pending.prefix(afterCount)), voice: idx)
            ? Array(pending.dropFirst(afterCount))
            : pending
        chord.graceNotesBefore = IdentifiedArray(Array(chord.graceNotesBefore) + leading)
        voices[idx].append(.chord(chord))
    }

    /// Queue a grace note (`<grace>`) for the next chord in its voice: it opens a grace chord of `shape`, or joins the
    /// pending one when it carries `<chord/>`. `endsAfterGraces` marks every grace queued so far as leaning back on
    /// the previous chord. Graces still pending when the measure ends lean back too (`build()`).
    mutating func appendGrace(
        _ note: Note,
        shape: MusicXMLNoteDecoder.GraceChordShape,
        joinsChord: Bool,
        endsAfterGraces: Bool,
        toVoice voiceId: String,
    ) {
        let idx = internVoice(voiceId)
        var pending = pendingGraces[idx, default: []]
        if joinsChord, var last = pending.popLast() {
            last.notes = ChordNotes(Array(last.notes) + [note])
            pending.append(last)
        } else {
            pending.append(GraceChord(graceType: shape.graceType, duration: shape.duration, notes: [note]))
        }
        pendingGraces[idx] = pending
        if endsAfterGraces { pendingAfterGraceCount[idx] = pending.count }
    }

    func elements(forVoice voiceId: String) -> [VoiceElement] {
        guard let idx = voiceIndex[voiceId] else { return [] }
        return voices[idx]
    }

    /// Positional voice index in the eventual built measure for the
    /// given MusicXML voice id. Returns `nil` before any append has
    /// claimed a slot for `voiceId`. Note that voice 0 may still be
    /// reassigned to the first real voice id (see `internVoice`); call
    /// this only after the relevant `append(_:toVoice:)`.
    func voicePositionIndex(forVoice voiceId: String) -> Int? {
        voiceIndex[voiceId]
    }

    /// Fold a `<chord/>` tone into the voice's last chord. Its articulations join the chord's, each kind once —
    /// a chord's tones commonly repeat the chord's marks, and MuseScore drops a duplicate the same way
    /// (`Chord::hasArticulation` in `addArticulationToChord`).
    mutating func foldIntoLastChord(
        voice voiceId: String, note: Note, duration: NoteDuration, articulations: [ChordArticulation] = [],
    ) {
        let idx = internVoice(voiceId)
        var elements = voices[idx]
        if let last = elements.last, case var .chord(chord) = last {
            chord.notes = ChordNotes(Array(chord.notes) + [note])
            let present = Set(chord.articulations.map(\.kind))
            chord.articulations += articulations.filter { !present.contains($0.kind) }
            elements[elements.count - 1] = .chord(chord)
        } else {
            elements.append(.chord(Chord(duration: duration, notes: [note], articulations: articulations)))
        }
        voices[idx] = elements
    }

    mutating func apply(barline: MusicXMLBarlineDecoder.Decoded) {
        switch barline.placement {
        case .start:
            if barline.startRepeat { startRepeat = true }
            if let line = barline.inline {
                appendToDefaultVoice(.barLine(line))
            }
        case .middle:
            if let line = barline.inline {
                appendToDefaultVoice(.barLine(line))
            }
        case .end:
            if let count = barline.endRepeatCount { endRepeatCount = count }
            if let line = barline.inline { trailingBarline = line }
        }
    }

    func build() -> Built {
        // Graces still pending at the end of the measure lean back on their voice's last chord (MuseScore's
        // "convert remaining grace chords to grace after"); a voice with no chord drops them, as MuseScore does.
        var settled = self
        for (idx, pending) in pendingGraces {
            _ = settled.attachBack(pending, voice: idx)
        }
        var final = settled.voices
        if let trailing = trailingBarline {
            if final.isEmpty {
                final.append([])
            }
            let targetIdx: Int
            if let id = defaultVoiceId, let idx = voiceIndex[id] {
                targetIdx = idx
            } else {
                targetIdx = 0
            }
            final[targetIdx].append(.barLine(trailing))
        }
        let builtVoices = final.isEmpty
            ? [Voice(elements: [])]
            : final.map { Voice(elements: $0) }
        // Markers and jumps join the part's first staff after the walk (`MusicXMLRepeatLog`).
        let measure = Measure(voices: builtVoices, startRepeat: startRepeat, endRepeatCount: endRepeatCount)
        return Built(measure: measure, systemElements: systemElements, anchors: anchors.first ?? [])
    }

    // MARK: - private helpers

    /// Hangs `graces` on the last chord of voice `idx` as MuseScore's `addGraceChordsAfter` does: each becomes its
    /// after-grace form (`Chord::toGraceAfter` — an appoggiatura, `grace16` or `grace32` turns into `grace8after`,
    /// `grace16after` or `grace32after`), and one with no after form, an acciaccatura or a `grace4`, stays a grace
    /// before that chord, since MuseScore files a grace by its type. False, with nothing changed, when the voice has
    /// no chord to lean on; true for no graces.
    private mutating func attachBack(_ graces: [GraceChord], voice idx: Int) -> Bool {
        guard !graces.isEmpty else { return true }
        guard voices.indices.contains(idx),
              let chordIdx = voices[idx].lastIndex(where: { if case .chord = $0 { true } else { false } }),
              case var .chord(chord) = voices[idx][chordIdx]
        else { return false }
        for grace in graces {
            var after = grace
            after.graceType = Self.afterForm(of: grace.graceType)
            if after.graceType.isAfter {
                chord.graceNotesAfter = IdentifiedArray(Array(chord.graceNotesAfter) + [after])
            } else {
                chord.graceNotesBefore = IdentifiedArray(Array(chord.graceNotesBefore) + [after])
            }
        }
        voices[idx][chordIdx] = .chord(chord)
        return true
    }

    /// `Chord::toGraceAfter`.
    private static func afterForm(of type: GraceType) -> GraceType {
        switch type {
        case .appoggiatura: .grace8after
        case .grace16: .grace16after
        case .grace32: .grace32after
        default: type
        }
    }

    private mutating func ensureFirstVoice() {
        if voices.isEmpty {
            voices.append([])
            anchors.append([])
            voiceIndex["__implicit__"] = 0
        }
    }

    private mutating func internVoice(_ voiceId: String) -> Int {
        if let idx = voiceIndex[voiceId] { return idx }
        // If we seeded voice 0 with attributes only and this is the first real
        // voice, adopt that slot instead of creating a new one.
        if voices.count == 1, voiceIndex.values.first == 0,
           voiceIndex["__implicit__"] != nil, voiceIndex.count == 1
        {
            voiceIndex.removeValue(forKey: "__implicit__")
            voiceIndex[voiceId] = 0
            return 0
        }
        let idx = voices.count
        voices.append([])
        anchors.append([])
        voiceIndex[voiceId] = idx
        return idx
    }

    private mutating func appendToDefaultVoice(_ element: VoiceElement) {
        if let id = defaultVoiceId {
            append(element, toVoice: id)
        } else {
            appendAttribute(element)
        }
    }
}
