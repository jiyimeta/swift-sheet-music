import Foundation
import SheetMusicCore

extension MidiImporter {
    // MARK: - Core assembly

    static func buildScore(
        file: MidiFile,
        imports: [ImportTrack],
        timeline: BarTimeline,
        options: MidiImportOptions,
        sourceFilename: String?
    ) -> Score {
        let perTrackMeasures = imports.map { segment(track: $0, timeline: timeline) }
        let concertKey = firstConcertKey(in: file)
        var parts: [Part] = []
        var staves: [StaffContent] = []
        for (trackIdx, measures) in perTrackMeasures.enumerated() {
            let track = imports[trackIdx]
            let trackKey = track.isDrums ? 0 : concertKey
            let voices = measures.map { m -> Voice in
                let q = quantize(measure: m, division: file.division, options: options)
                return voice(
                    quantized: q,
                    measure: m,
                    division: file.division,
                    isDrumTrack: track.isDrums,
                    concertKey: trackKey
                )
            }
            var scoreMeasures = voices.map { Measure(voices: [$0]) }
            if options.detectGlissando, !track.isDrums {
                attachGlissandos(
                    measures: measures,
                    voices: voices,
                    into: &scoreMeasures,
                    division: file.division
                )
            }
            let staffID = staves.count + 1
            var staff = StaffContent(id: staffID, measures: scoreMeasures)
            // Tempo is global to the score — only staff 1 carries it.
            // Time signature is shared across every staff (bar lines
            // align). Key signature applies to all non-drum staves;
            // percussion staves render without a key sig.
            injectMetaEvents(
                file: file,
                timeline: timeline,
                into: &staff,
                includeTempo: staffID == 1,
                includeKeySignature: !track.isDrums
            )
            staves.append(staff)
            parts.append(makePart(for: track))
        }
        let meta = resolveTitle(file: file, sourceFilename: sourceFilename)
        return Score(division: file.division, parts: parts, staves: staves, metaTags: meta)
    }

    // MARK: - Glissando attachment

    static func attachGlissandos(
        measures: [ImportMeasure],
        voices: [Voice],
        into scoreMeasures: inout [Measure],
        division: Int
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

    // MARK: - Meta event injection

    static func injectMetaEvents(
        file: MidiFile,
        timeline: BarTimeline,
        into staff: inout StaffContent,
        includeTempo: Bool,
        includeKeySignature: Bool
    ) {
        let metas = file.tracks.flatMap(\.events).filter {
            if case .meta = $0.event { true } else { false }
        }
        for meta in metas {
            let measureIdx = timeline.measureIndex(of: meta.tick)
            guard measureIdx < staff.measures.count else { continue }
            let element: VoiceElement?
            switch meta.event {
            case let .meta(.tempo(micros)):
                guard includeTempo else { continue }
                let bps = 1_000_000.0 / Double(micros)
                element = .tempo(Tempo(beatsPerSecond: bps))
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
                staff.measures[measureIdx].voices[0] = voice
            }
        }
    }

    // MARK: - Part building

    static func makePart(for track: ImportTrack) -> Part {
        let instrument: Instrument
        if track.isDrums {
            instrument = Instrument(
                id: "drumset",
                longName: track.trackName ?? "Drumset",
                useDrumset: true,
                drumLineMap: [:]
            )
        } else {
            instrument = Instrument(
                id: gmInstrumentID(for: track.programChange),
                longName: track.trackName ?? "Track"
            )
        }
        return Part(
            id: "P\(track.trackIndex)",
            trackName: track.trackName,
            instrument: instrument
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
        sourceFilename: String?
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
