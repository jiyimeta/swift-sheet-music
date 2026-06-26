import Foundation
import SheetMusicCore

extension MidiImporter {
    // MARK: - Core assembly

    static func buildScore(
        file: MidiFile,
        imports: [ImportTrack],
        timeline: BarTimeline,
        options: MidiImportOptions,
        sourceFilename: String?,
    ) -> Score {
        let perTrackMeasures = imports.map { segment(track: $0, timeline: timeline) }
        let measureKeys = perMeasureKeys(file: file, timeline: timeline)
        var parts: [Part] = []
        var systemMeasures: [SystemMeasure] = Array(
            repeating: SystemMeasure(),
            count: timeline.bars.count,
        )
        for (trackIdx, measures) in perTrackMeasures.enumerated() {
            let track = imports[trackIdx]
            let measureVoices: [[Voice]] = measures.map { m in
                let q = quantize(measure: m, division: file.division, options: options)
                let key = track.isDrums
                    ? 0
                    : (m.measureIndex < measureKeys.count ? measureKeys[m.measureIndex] : 0)
                if track.isDrums {
                    return drumVoices(
                        measure: m, quantized: q,
                        division: file.division, maxDots: options.maxDots,
                    )
                }
                return [voice(
                    quantized: q,
                    measure: m,
                    division: file.division,
                    isDrumTrack: false,
                    concertKey: key,
                    maxDots: options.maxDots,
                )]
            }
            var scoreMeasures = measureVoices.map { Measure(voices: $0) }
            if options.detectGlissando, !track.isDrums {
                attachGlissandos(
                    measures: measures,
                    voices: measureVoices.compactMap(\.first),
                    into: &scoreMeasures,
                    division: file.division,
                )
            }
            attachLyrics(
                track: track, measures: measures,
                into: &scoreMeasures, division: file.division,
            )
            // Build the Staff directly (replaces separate StaffContent + StaffDeclaration).
            // Tempo is global to the score — only track 0 carries it.
            // Time signature is shared across every staff (bar lines
            // align). Key signature applies to all non-drum staves;
            // percussion staves render without a key sig.
            // Drum tracks render on MuseScore's 5-line percussion
            // staff — `perc5Line` is the StaffType name MuseScore
            // matches against its built-in template. Using
            // `stdNormal` for a percussion-grouped staff confuses
            // MuseScore's loader: it treats the staff as a pitched
            // one and ignores the per-pitch `<Drum>` line positions,
            // collapsing every drum onto the same line visually.
            let defaultClef: NotatedClef = track.isDrums
                ? .percussion
                : inferClef(events: track.events, candidates: options.clefCandidates)
            var staff = Staff(
                staffType: track.isDrums ? "perc5Line" : "stdNormal",
                group: track.isDrums ? "percussion" : "pitched",
                defaultClefType: defaultClef.rawType,
                measures: scoreMeasures,
            )
            let staffAddress = StaffAddress(
                partIndex: parts.count,
                staffIndexInPart: 0,
            )
            injectMetaEvents(
                file: file,
                timeline: timeline,
                into: &staff,
                systemMeasures: &systemMeasures,
                staffAddress: staffAddress,
                includeTempo: trackIdx == 0,
                includeKeySignature: !track.isDrums,
            )
            parts.append(makePart(for: track, staff: staff))
        }
        let meta = resolveTitle(file: file, sourceFilename: sourceFilename)
        return Score(
            division: file.division,
            parts: parts,
            systemMeasures: systemMeasures,
            metaTags: meta,
            source: .midi,
        )
    }

    // MARK: - Drum voice splitting

    /// Split a drum measure into voice 0 (hands: cymbals, hi-hat,
    /// snare, toms) and voice 1 (feet: kick, low floor tom, pedal
    /// hi-hat) per `gmDrumVoiceIndex`. If voice 1 has no actual
    /// drum hits, omit it so the layout doesn't draw a redundant
    /// rest staff.
    static func drumVoices(
        measure: ImportMeasure,
        quantized: QuantizedMeasure,
        division: Int,
        maxDots: Int,
    ) -> [Voice] {
        let v0Pitches = pitchesInVoice(0, in: measure)
        let v1Pitches = pitchesInVoice(1, in: measure)
        var result: [Voice] = []
        // Voice 0 always emitted (even if empty — keeps clef + rests).
        result.append(voice(
            quantized: quantized,
            measure: filterMeasure(measure, keepingPitches: v0Pitches),
            division: division,
            isDrumTrack: true,
            maxDots: maxDots,
        ))
        if !v1Pitches.isEmpty {
            result.append(voice(
                quantized: quantized,
                measure: filterMeasure(measure, keepingPitches: v1Pitches),
                division: division,
                isDrumTrack: true,
                maxDots: maxDots,
            ))
        }
        return result
    }

    private static func pitchesInVoice(
        _ voiceIdx: Int, in measure: ImportMeasure,
    ) -> Set<Int> {
        var pitches: Set<Int> = []
        for ev in measure.events {
            if case let .noteOn(_, p, v) = ev.event, v > 0,
               gmDrumVoiceIndex(for: p) == voiceIdx
            {
                pitches.insert(p)
            }
        }
        return pitches
    }

    private static func filterMeasure(
        _ measure: ImportMeasure, keepingPitches pitches: Set<Int>,
    ) -> ImportMeasure {
        var copy = measure
        copy.events = measure.events.filter { ev in
            switch ev.event {
            case let .noteOn(_, p, _), let .noteOff(_, p, _):
                return pitches.contains(p)
            default:
                return true // keep meta / endOfTrack
            }
        }
        copy.carryIns = measure.carryIns.filter { pitches.contains($0.pitch) }
        copy.carryOuts = measure.carryOuts.filter { pitches.contains($0.pitch) }
        return copy
    }

    // MARK: - Glissando attachment

    static func attachGlissandos(
        measures: [ImportMeasure],
        voices: [Voice],
        into scoreMeasures: inout [Measure],
        division: Int,
    ) {
        for (i, measure) in measures.enumerated() {
            let attachments = detectGlissandos(measure: measure, division: division)
            guard !attachments.isEmpty else { continue }
            guard var voiceVal = scoreMeasures[i].voices.first else { continue }
            for att in attachments {
                for (ei, element) in voiceVal.elements.enumerated() {
                    guard case var .chord(chord) = element else { continue }
                    guard chord.notes.contains(where: { $0.pitch == att.pitch }) else { continue }
                    var notesArray = Array(chord.notes)
                    if let idx = notesArray.firstIndex(where: { $0.pitch == att.pitch }) {
                        notesArray[idx].glissando = att.glissando
                    }
                    chord.notes = ChordNotes(notesArray)
                    voiceVal.elements[ei] = .chord(chord)
                    break
                }
            }
            scoreMeasures[i].voices[0] = voiceVal
        }
    }

    // MARK: - Key-signature lookup

    /// First key-signature meta event found anywhere in the file
    /// (any track), as a sharps/flats count. `0` if absent.
    /// Used to choose enharmonic spellings during voicing.
    static func firstConcertKey(in file: MidiFile) -> Int {
        for track in file.tracks {
            for ev in track.events {
                if case let .meta(.keySignature(sf, _)) = ev.event {
                    return sf
                }
            }
        }
        return 0
    }

    /// Active key-signature value for each measure index.
    /// Key changes mid-piece (e.g. modulating from 4 flats to 3
    /// sharps) take effect at the bar containing the change.
    ///
    /// Source: Format 1 conductor track (track 0); Format 0 single
    /// track. Other tracks' key-sig events are ignored — DAWs often
    /// duplicate them per instrument track and (notably) write a
    /// stray `sf=0` on drum tracks because percussion has no key,
    /// which would otherwise compete with the real value at tick 0.
    static func perMeasureKeys(
        file: MidiFile, timeline: BarTimeline,
    ) -> [Int] {
        struct Change { var tick: Int; var sf: Int }
        var changes: [Change] = []
        let conductor = file.tracks.first
        for ev in conductor?.events ?? [] {
            if case let .meta(.keySignature(sf, _)) = ev.event {
                changes.append(Change(tick: ev.tick, sf: sf))
            }
        }
        changes.sort { $0.tick < $1.tick }
        if changes.first?.tick != 0 {
            changes.insert(Change(tick: 0, sf: 0), at: 0)
        }

        return timeline.bars.map { bar in
            var current = 0
            for change in changes {
                if change.tick <= bar.startTick {
                    current = change.sf
                } else {
                    break
                }
            }
            return current
        }
    }

    // MARK: - Meta event injection

    static func injectMetaEvents(
        file: MidiFile,
        timeline: BarTimeline,
        into staff: inout Staff,
        systemMeasures: inout [SystemMeasure],
        staffAddress: StaffAddress,
        includeTempo: Bool,
        includeKeySignature: Bool,
    ) {
        // Format 1 convention: tempo / time-sig / key-sig are all
        // on the conductor (track 0). DAWs frequently duplicate
        // them per instrument track, and write `sf=0` on drum
        // tracks specifically (percussion has no key signature).
        // Walking every track here would double-insert events and
        // — worse — let the drum track's spurious (0, 0) override
        // the real initial key on every non-drum staff.
        // The final voice order MuseScore expects at the start of a
        // measure is `KeySig → TimeSig → Tempo → Chord/Rest`. Each
        // meta element is `insert(at: 0)`-ed below, which reverses
        // the visit order — so visit them in the opposite of the
        // desired final order: Tempo first, then TimeSig, then
        // KeySig. Sorting by `(tick, reverse-priority)` keeps metas
        // at later measures ordered correctly too.
        let metaPriority: (TimedMidiEvent) -> Int = { ev in
            if case let .meta(meta) = ev.event {
                switch meta {
                case .tempo: return 0
                case .timeSignature: return 1
                case .keySignature: return 2
                default: return 3
                }
            }
            return 4
        }
        let metas = (file.tracks.first?.events ?? [])
            .filter { if case .meta = $0.event { true } else { false } }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.tick != rhs.element.tick {
                    return lhs.element.tick < rhs.element.tick
                }
                let lp = metaPriority(lhs.element)
                let rp = metaPriority(rhs.element)
                if lp != rp { return lp < rp }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        for meta in metas {
            let measureIdx = timeline.measureIndex(of: meta.tick)
            guard measureIdx < staff.measures.count else { continue }
            let element: VoiceElement?
            switch meta.event {
            case let .meta(.tempo(micros)):
                guard includeTempo else { continue }
                let bps = 1_000_000.0 / Double(micros)
                // Tempo now lives on the score-level `SystemMeasure`
                // rather than voice elements. Imported MIDI tempo
                // changes attach at measure start — MIDI files don't
                // routinely carry sub-measure positioning needed for
                // anything finer, and the previous "insert at index 0
                // of voice 0" approach landed at the same effective
                // position (cursor 0 of the measure).
                if measureIdx < systemMeasures.count {
                    systemMeasures[measureIdx].elements.append(
                        PositionedSystemElement(
                            position: .start,
                            element: .tempo(Tempo(beatsPerSecond: bps)),
                            originalStaff: staffAddress,
                        ),
                    )
                }
                continue
            case let .meta(.timeSignature(n, d, _, _)):
                element = .timeSignature(TimeSignature(numerator: n, denominator: d))
            case let .meta(.keySignature(sf, _)):
                guard includeKeySignature else { continue }
                element = .keySignature(KeySignature(concertKey: sf))
            default:
                element = nil
            }
            if let el = element, var voice = staff.measures[measureIdx].voices.first {
                voice.elements.insert(el, at: 0)
                // Voice.tuplets references chord indices in
                // `elements`. Inserting at index 0 shifts every
                // subsequent index by one — bump the tuplet ranges
                // so they keep pointing at the same chords (otherwise
                // the bracket gets drawn over the meta event we just
                // inserted, or disappears entirely).
                voice.tuplets = voice.tuplets.map {
                    Tuplet(
                        normalNotes: $0.normalNotes,
                        actualNotes: $0.actualNotes,
                        startIndex: $0.startIndex + 1,
                        endIndex: $0.endIndex + 1,
                    )
                }
                staff.measures[measureIdx].voices[0] = voice
            }
        }
    }

    // MARK: - Part building

    static func makePart(for track: ImportTrack, staff: Staff) -> Part {
        let instrument: Instrument
        if track.isDrums {
            instrument = Instrument(
                id: "drumset",
                longName: track.trackName ?? "Drumset",
                useDrumset: true,
                drumLineMap: gmDrumLines,
            )
        } else {
            instrument = Instrument(
                id: gmInstrumentID(for: track.programChange),
                longName: track.trackName ?? "Track",
            )
        }
        return Part(
            id: "P\(track.trackIndex)",
            trackName: track.trackName,
            instrument: instrument,
            staves: [staff],
        )
    }

    static func gmInstrumentID(for program: Int?) -> String {
        guard let p = program else { return "piano" }
        switch p {
        case 0 ... 7: return "piano"
        case 24 ... 31: return "guitar"
        case 32 ... 39: return "bass"
        case 40 ... 47: return "violin"
        case 56 ... 63: return "trumpet"
        case 64 ... 71: return "saxophone"
        case 72 ... 79: return "flute"
        default: return "piano"
        }
    }

    // MARK: - Title resolution

    static func resolveTitle(
        file: MidiFile,
        sourceFilename: String?,
    ) -> [String: String] {
        var meta: [String: String] = [:]
        let track0 = file.tracks.first
        let track0HasNotes = track0?.events.contains {
            if case .noteOn = $0.event { true } else { false }
        } ?? false
        let track0Name = track0?.events.compactMap { ev -> String? in
            if case let .meta(.trackName(name)) = ev.event { return name }
            return nil
        }.first

        if file.format == 1, !track0HasNotes, let name = track0Name, !name.isEmpty {
            meta["workTitle"] = name
        } else if file.format == 0, let name = track0Name, !name.isEmpty {
            meta["workTitle"] = name
        } else if let filename = sourceFilename, !filename.isEmpty {
            meta["workTitle"] = filename
        }
        return meta
    }
}
