import SheetMusicCore
import SheetMusicFoundation

/// A dynamic or a hairpin somewhere in a part, at its original tick, with the staff and voice it is written in.
/// MuseScore 4 lays each one into every voice its `VoiceAssignment` reaches (`applyDynamic`,
/// `engraving/playback/playbackcontext.cpp:805-837`) — by default the whole instrument.
struct PartDynamicEvent {
    enum Payload {
        case dynamic(Dynamic)
        case hairpin(Spanner.HairpinPayload, endTick: Int)
    }

    let tick: Int
    let measureIndex: Int
    let tickInMeasure: Int
    let staffIndex: Int
    let voiceIndex: Int
    /// Its place in its voice, in file order.
    let order: Int
    let payload: Payload

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
        if case .dynamic = payload { 0 } else { 1 }
    }
}

/// What one voice's walk finds: its dynamics and hairpins, and where its chords stand.
struct VoiceDynamicsRecord {
    var events: [PartDynamicEvent] = []
    var chords: [(tick: Int, ticks: Int)] = []
}

extension HairpinRamps {
    /// One voice of one staff, walked measure by measure — a measure repeat lends its source's dynamics at its own
    /// ticks (MuseScore 4's `handleMeasureRepeats`, `playbackcontext.cpp:765-803`); hairpins are read where written.
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
                walkVoice(
                    voice, measureIdx: measureIdx, measureBase: measureBase, measureDuration: measureDuration,
                    measures: staff.measures, division: division, tempoMap: tempoMap,
                    readsDynamics: readsDynamics, readsHairpins: readsHairpins,
                    staffIndex: staffIndex, voiceIndex: voiceIndex, record: &record,
                )
            }
            measureBase += MidiRenderer.measureTicks(
                measure: measure, division: division, measureDuration: measureDuration,
                measureIndex: measureIdx, tempoMap: tempoMap,
            )
        }
        return record
    }

    /// Voice `voiceIndex` of staff `staffIndex`'s dynamics timeline: every dynamic and hairpin of `staves` that reaches
    /// it (`PartDynamicEvent.reaches`), applied in MuseScore's order (`appliesBefore`) against its own chords.
    static func timeline(
        staffIndex: Int,
        voiceIndex: Int,
        staves: [Staff],
        instrument: Instrument,
        division: Int,
        tempoMap: ResolvedTempoMap,
    ) -> DynamicsTimeline {
        var events: [PartDynamicEvent] = []
        var chords: [(tick: Int, ticks: Int)] = []
        for (index, staff) in staves.enumerated() {
            let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
            for voice in 0 ..< voiceCount {
                let found = record(
                    staffIndex: index, voiceIndex: voice, staff: staff, division: division, tempoMap: tempoMap,
                )
                events += found.events.filter { $0.reaches(staff: staffIndex, voice: voiceIndex) }
                if index == staffIndex, voice == voiceIndex { chords = found.chords }
            }
        }
        events.sort(by: PartDynamicEvent.appliesBefore)
        let initialVelocity = MidiRenderer.effectiveVelocity(forDynamic: nil, instrument: instrument)
        var walk = DynamicsWalk(runningVelocity: initialVelocity)
        var next = events.startIndex
        for chord in chords + [(tick: Int.max, ticks: 0)] {
            while next < events.endIndex, events[next].tick <= chord.tick {
                walk.apply(events[next], instrument: instrument, division: division, tempoMap: tempoMap)
                next += 1
            }
            walk.close(chordAt: chord.tick, ticks: chord.ticks)
        }
        return walk.timeline(initialVelocity: initialVelocity)
    }
}
