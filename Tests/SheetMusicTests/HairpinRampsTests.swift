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

    private func ppp() -> Dynamic {
        Dynamic(subtype: "ppp", velocity: 16)
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
        #expect(ramps.filter { $0.role == .wedge }.count == 1)
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
        let wedges = ramps.filter { $0.role == .wedge }
        #expect(wedges.count == 2)
        #expect(wedges[0].endVelocity == 96)
        #expect(wedges[1].startVelocity == 96)
        #expect(wedges[1].endVelocity == 49)
    }

    /// Only a Dynamic anchored at the hairpin's own end tick brackets
    /// it. MuseScore 4 resolves the end level from the dynamic *snapped*
    /// to the last hairpin segment
    /// (`PlaybackContext::findNominalEndDynamicType` →
    /// `HairpinSegment::findElementToSnapAfter`), never from the next
    /// dynamic wherever it happens to be. A `ppp` four measures later
    /// describes a different passage, not this hairpin's target.
    @Test func distantDynamicDoesNotBracketTheHairpin() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
            makeMeasure([
                .dynamic(ppp()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
        )
        #expect(ramps.first?.endVelocity == 64 + HairpinRamps.defaultDeltaVelocity)
    }

    /// A bracketing Dynamic that contradicts the wedge — a crescendo
    /// ending on a *quieter* mark — is not the hairpin's target either.
    /// MuseScore 4 keeps the default step in that case
    /// (`useNominalLevelTo` requires `nominalLevelTo > levelFrom` for a
    /// crescendo); MuseScore 3.6 flattens the ramp instead
    /// (`ChangeMap::cleanupStage3`). Either way it never ramps backwards.
    @Test func endDynamicContradictingTheWedgeIsIgnored() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
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
        #expect(ramps.first?.endVelocity == 64 + HairpinRamps.defaultDeltaVelocity)
    }

    /// Mirror of `endDynamicContradictingTheWedgeIsIgnored` for a
    /// diminuendo running into a *louder* mark.
    @Test func endDynamicContradictingTheDiminuendoIsIgnored() {
        let s = staff([
            makeMeasure([
                .dynamic(f()), .spanner(decresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(Dynamic(subtype: "ff", velocity: 112)),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
        )
        #expect(ramps.first?.endVelocity == 96 - HairpinRamps.defaultDeltaVelocity)
    }

    /// An explicit `<veloChange>` is MuseScore 3's own way of spelling
    /// the ramp's size, and it wins over the bracketing Dynamic there:
    /// `Score::updateHairpin` passes it straight to `addRamp`, and only
    /// a change of `0` sends `ChangeMap` looking for a neighbouring fix.
    @Test func explicitVeloChangeWinsOverBracketDynamic() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc(veloChange: 20)),
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
        #expect(ramps.first?.endVelocity == 84) // 64 + 20, not the f's 96
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

    /// A hairpin that starts partway through a measure ends where its
    /// `<location>` says, and that location is **relative to the
    /// hairpin's own tick** — `<measures>1</measures>` walks one
    /// measure on from there and `<fractions>-7/8</fractions>` then
    /// steps back, which is how MuseScore spells "from beat 4 of this
    /// measure to the next downbeat". Re-deriving the end from the
    /// measure base instead drops the hairpin's own offset, and the
    /// subtraction lands the end *before* the start — collapsing a real
    /// crescendo to a single tick, which reads at playback as the wedge
    /// having no effect at all.
    ///
    /// `OttavaRanges.computeEndTick` and `LayoutEngine.endAnchor`
    /// already resolve it this way; this is the third copy agreeing.
    @Test func aHairpinStartingMidMeasureEndsWhereItsLocationSays() {
        let s = staff([
            makeMeasure([
                quarter(), quarter(), quarter(),
                .dynamic(ppp()),
                .spanner(Spanner(
                    kind: .hairpin, rawType: "HairPin",
                    nextMeasuresOffset: 1,
                    nextFractionsOffset: Fraction(numerator: -3, denominator: 4),
                    hairpin: .init(subtype: .crescendo),
                )),
                quarter(),
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
        let wedge = ramps.first { $0.role == .wedge }
        #expect(wedge?.startTick == 1440)
        #expect(wedge?.endTick == 1920)
        #expect(wedge?.startVelocity == 16)
        #expect(wedge?.endVelocity == 96)
    }

    /// The level a hairpin reaches is where the part stays until the
    /// next Dynamic says otherwise — a crescendo is not undone by its
    /// own last note. Both MuseScore generations hold it: MS3's
    /// `ChangeMap::val` returns `cachedEndVal` for every tick past a
    /// ramp until the next event, and MS4 writes the ramp's levels into
    /// the same dynamics map the following notes read.
    @Test func theLevelReachedHoldsUntilTheNextDynamic() throws {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let part = Part(id: "P1", instrument: instrument(), staves: [s])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(
                defaultChannel: 0, defaultPort: 0, switches: [],
            ),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        #expect(velocities.count == 12)
        // Measure 3 sits past the wedge with no dynamic of its own and
        // stays at the `f` the crescendo arrived on.
        #expect(Array(velocities[8...]) == Array(repeating: 96, count: 4))
    }

    /// …but a level nobody wrote down does not travel. A part with a
    /// dozen `cresc.` wedges and no dynamic at all — the shape of most
    /// hand-entered charts — would otherwise ratchet up by the default
    /// step per wedge and never come back down, an invented number
    /// compounding across the whole piece. MuseScore 3 has no default
    /// step to compound (`veloChange` defaults to 0), and both MuseScore
    /// generations export such a part at a flat level.
    @Test func aGuessedLevelStaysInsideItsOwnWedge() throws {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
            makeMeasure([
                .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let part = Part(id: "P1", instrument: instrument(), staves: [s])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(
                defaultChannel: 0, defaultPort: 0, switches: [],
            ),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        let reached = 64 + HairpinRamps.defaultDeltaVelocity
        // Each wedge swells to the same guessed level and relaxes; the
        // second starts from the written `mp`, not from the first's guess.
        #expect(velocities[0] == 64)
        #expect(velocities[4] == reached)
        #expect(velocities[5] == 64)
        #expect(velocities[8] == 64)
        #expect(velocities[12] == reached)
        #expect(velocities.max() == reached)
    }

    /// A second hairpin picks up where the first left off. MS3 spells
    /// this out in `ChangeMap::cleanupStage3`: a ramp with no fix at its
    /// own tick takes the previous event's value, and for a preceding
    /// ramp that value is its `cachedEndVal`.
    @Test func aSecondHairpinStartsFromTheFirstsEndLevel() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc(veloChange: 20)),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
        )
        let wedges = ramps.filter { $0.role == .wedge }
        #expect(wedges.count == 2)
        let reached = 64 + 20 // the first wedge's own `<veloChange>`
        #expect(wedges[1].startVelocity == reached)
        #expect(wedges[1].endVelocity == reached + HairpinRamps.defaultDeltaVelocity)
    }

    /// A Dynamic the wedge could not adopt still governs its own note.
    /// The ramp has to stop just short of it, exactly as MuseScore 4
    /// trims the span (`spannerTo -= Fraction::eps()` when a dynamic
    /// sits on the end tick and is not the level being ramped to) —
    /// otherwise the ramp's own end value would overwrite the mark the
    /// engraver wrote.
    @Test func ignoredEndDynamicStillSoundsAtItsOwnTick() throws {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(p()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let part = Part(id: "P1", instrument: instrument(), staves: [s])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(
                defaultChannel: 0, defaultPort: 0, switches: [],
            ),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        #expect(velocities.first == 64)
        // Downbeat of measure 2: the `p`, not the crescendo's target.
        #expect(velocities[4] == 49)
    }
}
