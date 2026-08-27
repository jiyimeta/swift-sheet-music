@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct HairpinRampsTests {
    private func ramp(
        startTick: Int = 0,
        endTick: Int = 480,
        startVelocity: Int = 60,
        endVelocity: Int = 112,
        method: Spanner.HairpinPayload.VeloChangeMethod = .normal,
    ) -> HairpinRamp {
        HairpinRamp(
            startTick: startTick,
            endTick: endTick,
            startVelocity: startVelocity,
            endVelocity: endVelocity,
            method: method,
        )
    }

    @Test func interpolateLinearMidpoint() {
        let r = ramp(startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 240) == 80)
    }

    @Test func interpolateClampsBeforeStart() {
        let r = ramp(startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: -100) == 60)
    }

    @Test func interpolateClampsAfterEnd() {
        let r = ramp(startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 1000) == 100)
    }

    @Test func interpolateSingleTickSpanReturnsEnd() {
        let r = ramp(startTick: 480, endTick: 480, startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 480) == 100)
    }

    @Test func nonNormalMethodsFallThroughToLinear() {
        for method: Spanner.HairpinPayload.VeloChangeMethod in
            [.easeIn, .easeOut, .easeInOut, .exponential]
        {
            let r = ramp(startVelocity: 60, endVelocity: 100, method: method)
            #expect(
                HairpinRamps.interpolate(ramp: r, atOriginalTick: 240) == 80,
                "method \(method) should fall through to linear in v1",
            )
        }
    }

    @Test func activeReturnsLatestContainingRamp() {
        let r1 = ramp(startTick: 0, endTick: 480)
        let r2 = ramp(startTick: 240, endTick: 720)
        #expect(HairpinRamps.active(in: [r1, r2], at: 100)?.startTick == 0)
        #expect(HairpinRamps.active(in: [r1, r2], at: 300)?.startTick == 240)
        #expect(HairpinRamps.active(in: [r1, r2], at: 1000) == nil)
    }
}

struct HairpinRampsCollectTests {
    private let division = 480

    private func instrument() -> Instrument {
        Instrument(id: "piano", articulations: [])
    }

    private func mp() -> Dynamic {
        Dynamic(subtype: "mp", velocity: 64)
    }

    private func f() -> Dynamic {
        Dynamic(subtype: "f", velocity: 96)
    }

    private func p() -> Dynamic {
        Dynamic(subtype: "p", velocity: 49)
    }

    private func quarter() -> VoiceElement {
        .chord(Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        ))
    }

    private func makeMeasure(_ elements: [VoiceElement]) -> Measure {
        Measure(voices: [Voice(elements: elements)])
    }

    private func staff(_ measures: [Measure]) -> Staff {
        Staff(measures: measures)
    }

    private func cresc(measures: Int = 1, veloChange: Int? = nil) -> Spanner {
        Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: measures,
            hairpin: .init(subtype: .crescendo, veloChange: veloChange),
        )
    }

    private func decresc(measures: Int = 1) -> Spanner {
        Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: measures,
            hairpin: .init(subtype: .decrescendo),
        )
    }

    @Test func bracketDynamicsOnBothSides() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
        )
        #expect(ramps.count == 1)
        #expect(ramps.first?.startVelocity == 64)
        #expect(ramps.first?.endVelocity == 96)
    }

    @Test func noBracketUsesVeloChange() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc(veloChange: 20)),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
        )
        #expect(ramps.first?.endVelocity == 84) // 64 + 20
    }

    @Test func noBracketNoVeloChangeUsesDefaultDelta() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
        )
        #expect(ramps.first?.endVelocity == 64 + HairpinRamps.defaultDeltaVelocity)
    }

    @Test func decrescendoSign() {
        let s = staff([
            makeMeasure([
                .dynamic(f()), .spanner(decresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(p()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
        )
        #expect(ramps.first?.startVelocity == 96)
        #expect(ramps.first?.endVelocity == 49)
        #expect(ramps.first?.endVelocity ?? 99 < ramps.first?.startVelocity ?? 0)
    }

    @Test func backToBackHairpinsShareMiddleDynamic() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()), .spanner(decresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(p()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
        )
        #expect(ramps.count == 2)
        #expect(ramps[0].endVelocity == 96)
        #expect(ramps[1].startVelocity == 96)
        #expect(ramps[1].endVelocity == 49)
    }

    /// End-to-end through MidiRenderer: the collected ramp is applied to
    /// the rendered note-on velocities.
    @Test func noteVelocitiesRampLinearly() throws {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let part = Part(
            id: "P1",
            instrument: instrument(),
            staves: [s],
        )
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        // 4 onsets in measure 1 ramp from 64 toward 96; chord at the
        // hairpin end (start of measure 2) is set by the bracket
        // Dynamic to 96 and is therefore exactly 96.
        #expect(velocities.first == 64)
        #expect(velocities[4] == 96)
        // Strictly monotonic across the ramp, no flat plateau.
        for i in 0 ..< 4 {
            #expect(velocities[i] < velocities[i + 1])
        }
    }
}
