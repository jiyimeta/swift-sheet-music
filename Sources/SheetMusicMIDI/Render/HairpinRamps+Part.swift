import SheetMusicCore
import SheetMusicFoundation

/// A staff of a part and a voice in it — one of MuseScore's tracks.
struct PartTrack: Hashable {
    let staff: Int
    let voice: Int
}

/// A dynamic or a hairpin somewhere in a part, at its original tick, with the staff and voice it is written in.
/// MuseScore 4 lays each one into every voice its `VoiceAssignment` reaches (`applyDynamic`,
/// `engraving/playback/playbackcontext.cpp:805-837`) — by default the whole instrument.
struct PartDynamicEvent {
    enum Payload {
        case dynamic(Dynamic)
        case hairpin(Spanner.HairpinPayload, endTick: Int)
    }

    /// An event's identity in its part: its track and its place there.
    struct Source: Hashable {
        let track: PartTrack
        let order: Int
    }

    let tick: Int
    let measureIndex: Int
    let tickInMeasure: Int
    let staffIndex: Int
    let voiceIndex: Int
    /// Its place in its voice, in file order.
    let order: Int
    let payload: Payload

    var track: PartTrack {
        PartTrack(staff: staffIndex, voice: voiceIndex)
    }

    var source: Source {
        Source(track: track, order: order)
    }

    var isHairpin: Bool {
        if case .hairpin = payload { true } else { false }
    }

    var voiceAssignment: VoiceAssignment {
        switch payload {
        case let .dynamic(dynamic): dynamic.voiceAssignment
        case let .hairpin(hairpin, _): hairpin.voiceAssignment
        }
    }

    /// Whether it plays in voice `voice` of staff `staff` (`applyDynamic`'s `trackAccepted`, `:813-824`).
    func reaches(staff: Int, voice: Int) -> Bool {
        switch voiceAssignment {
        case .allInInstrument: true
        case .allInStaff: staffIndex == staff
        case .currentVoiceOnly: staffIndex == staff && voiceIndex == voice
        }
    }

    /// The order a voice applies them in: a tick's dynamics before its hairpins (MuseScore lays hairpins out after
    /// every dynamic of the run, `:324-339`); among a tick's dynamics the narrower assignment last, so it is the one
    /// that stays (`:831-835`); then file order — staff, voice, place — the order MuseScore reads them in.
    static func appliesBefore(_ lhs: PartDynamicEvent, _ rhs: PartDynamicEvent) -> Bool {
        (lhs.tick, lhs.kindRank, lhs.voiceAssignment.priority, lhs.staffIndex, lhs.voiceIndex, lhs.order)
            < (rhs.tick, rhs.kindRank, rhs.voiceAssignment.priority, rhs.staffIndex, rhs.voiceIndex, rhs.order)
    }

    private var kindRank: Int {
        isHairpin ? 1 : 0
    }
}

/// What one voice's walk finds: its dynamics and hairpins, and where its chords stand.
struct VoiceDynamicsRecord {
    var events: [PartDynamicEvent] = []
    var chords: [(tick: Int, ticks: Int)] = []
}

extension HairpinRamps {
    /// One voice of one staff, walked measure by measure — a measure repeat lends its source's dynamics and chords at
    /// its own ticks (MuseScore 4's `handleMeasureRepeats`, `playbackcontext.cpp:765-803`); hairpins are read where
    /// written, so a measure repeat does not replay its source's.
    static func record(
        staffIndex: Int, voiceIndex: Int, staff: Staff, division: Int, tempoMap: ResolvedTempoMap,
    ) -> VoiceDynamicsRecord {
        var record = VoiceDynamicsRecord()
        var measureBase = 0
        let measureDurations = staff.measures.effectiveMeasureDurations()
        for (measureIdx, measure) in staff.measures.enumerated() {
            let measureDuration = measureIdx < measureDurations.count
                ? measureDurations[measureIdx]
                : Fraction(numerator: 4, denominator: 4)
            let literal = voiceIndex < measure.voices.count ? measure.voices[voiceIndex] : nil
            let resolved = MidiRenderer.resolvedVoice(measureIndex: measureIdx, staff: staff, voiceIndex: voiceIndex)
            let isRepeat = MidiRenderer.explicitMeasureRepeatInAnyVoice(of: measure) != nil
                || MidiRenderer.groupRepeatMarker(measureIndex: measureIdx, staff: staff, voiceIndex: voiceIndex) != nil
            let walks = [(resolved, true, !isRepeat), (isRepeat ? literal : nil, false, true)]
            for (voice, readsDynamics, readsHairpins) in walks {
                guard let voice else { continue }
                let chordCount = record.chords.count
                walkVoice(
                    voice, measureIdx: measureIdx, measureBase: measureBase, measureDuration: measureDuration,
                    measures: staff.measures, division: division, tempoMap: tempoMap,
                    readsDynamics: readsDynamics, readsHairpins: readsHairpins,
                    staffIndex: staffIndex, voiceIndex: voiceIndex, record: &record,
                )
                // The chords the voice plays are the resolved bar's; a repeat's own bar lends only its hairpins.
                if !readsDynamics { record.chords.removeSubrange(chordCount...) }
            }
            measureBase += MidiRenderer.measureTicks(
                measure: measure, division: division, measureDuration: measureDuration,
                measureIndex: measureIdx, tempoMap: tempoMap,
            )
        }
        return record
    }

    /// Voice `voiceIndex` of staff `staffIndex`'s dynamics timeline: every dynamic of `staves` that reaches it
    /// (`PartDynamicEvent.reaches`), applied in MuseScore's order (`appliesBefore`) against its own chords, and every
    /// hairpin that reaches it as resolved once on the track it is written in (`DynamicsWalk.resolvedWedges`) —
    /// MuseScore lays that one curve into each track the hairpin reaches (`handleHairpin`, `applyDynamic`,
    /// `playbackcontext.cpp:569-647`, `:805-837`).
    static func timeline(
        staffIndex: Int,
        voiceIndex: Int,
        staves: [Staff],
        instrument: Instrument,
        division: Int,
        tempoMap: ResolvedTempoMap,
    ) -> DynamicsTimeline {
        var events: [PartDynamicEvent] = []
        var chords: [PartTrack: [(tick: Int, ticks: Int)]] = [:]
        for (index, staff) in staves.enumerated() {
            let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
            for voice in 0 ..< voiceCount {
                let found = record(
                    staffIndex: index, voiceIndex: voice, staff: staff, division: division, tempoMap: tempoMap,
                )
                events += found.events
                chords[PartTrack(staff: index, voice: voice)] = found.chords
            }
        }
        events.sort(by: PartDynamicEvent.appliesBefore)
        let initialVelocity = MidiRenderer.effectiveVelocity(forDynamic: nil, instrument: instrument)

        func walk(_ track: PartTrack) -> DynamicsWalk {
            var walk = DynamicsWalk(runningVelocity: initialVelocity)
            let reaching = events.filter { $0.reaches(staff: track.staff, voice: track.voice) }
            var next = reaching.startIndex
            for chord in (chords[track] ?? []) + [(tick: Int.max, ticks: 0)] {
                while next < reaching.endIndex, reaching[next].tick <= chord.tick {
                    walk.apply(reaching[next], instrument: instrument, division: division, tempoMap: tempoMap)
                    next += 1
                }
                walk.close(chordAt: chord.tick, ticks: chord.ticks)
            }
            return walk
        }

        let target = PartTrack(staff: staffIndex, voice: voiceIndex)
        let own = walk(target)
        var resolved: [PartTrack: [PartDynamicEvent.Source: [HairpinRamp]]] = [:]
        var wedges: [HairpinRamp] = []
        for event in events where event.isHairpin && event.reaches(staff: staffIndex, voice: voiceIndex) {
            if resolved[event.track] == nil {
                let origin = event.track == target ? own : walk(event.track)
                resolved[event.track] = origin.resolvedWedges(writtenIn: event.track)
            }
            wedges += resolved[event.track]?[event.source] ?? []
        }
        return own.timeline(initialVelocity: initialVelocity, wedges: wedges)
    }
}
