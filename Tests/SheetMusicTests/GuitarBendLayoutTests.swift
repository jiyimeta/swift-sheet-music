#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// Angular- and slight-bend geometry, ported from MuseScore's
    /// `GuitarBendLayout` (`rendering/score/guitarbendlayout.cpp`).
    @Suite("GuitarBendGeometry")
    struct GuitarBendGeometryTests {
        @Test("vertex height clamps between 0.75sp and 2sp")
        func vertexClamp() {
            let sp: CGFloat = 10
            // run == 1sp → minimum height
            let short = GuitarBendGeometry.vertex(
                from: .zero, to: CGPoint(x: 10, y: 0), sp: sp, up: true,
            )
            #expect(abs(short.y - -7.5) < 0.01) // 0.75sp above a horizontal run
            // very long run → clamped at 2sp
            let long = GuitarBendGeometry.vertex(
                from: .zero, to: CGPoint(x: 1000, y: 0), sp: sp, up: true,
            )
            #expect(abs(long.y - -20) < 0.01)
            #expect(abs(long.x - 500) < 0.01) // midpoint
        }

        @Test("down bend puts the vertex below")
        func downVertex() {
            let v = GuitarBendGeometry.vertex(
                from: .zero, to: CGPoint(x: 100, y: 0), sp: 10, up: false,
            )
            #expect(v.y > 0)
        }

        @Test("vertex is expressed in the same absolute frame as its endpoints")
        func vertexIsAbsolute() {
            // Same run as `vertexClamp`'s long case, translated by
            // (100, 40): the vertex must translate with it rather than
            // stay relative to the start anchor.
            let v = GuitarBendGeometry.vertex(
                from: CGPoint(x: 100, y: 40),
                to: CGPoint(x: 1100, y: 40),
                sp: 10, up: true,
            )
            #expect(abs(v.x - 600) < 0.01)
            #expect(abs(v.y - 20) < 0.01) // 40 - 2sp
        }

        @Test("a sloped run tilts the vertex displacement")
        func slopedRun() {
            // dx == dy == 100 ⇒ angle = -atan(1) = -45°, so the
            // displacement is (upSign · h · sin θ, upSign · h · cos θ)
            // with h = min(max(0.75sp + 0.1·(100 - sp), 0.75sp), 2sp)
            // = 7.5 + 9 = 16.5 (short of the 2sp = 20 cap).
            // upSign = -1, sin(-45°) = -√2/2, cos(-45°) = √2/2, so the
            // vertex leaves the midpoint (50, 50) perpendicular to the
            // descending run: right and up by 16.5·√2/2.
            let sp: CGFloat = 10
            let v = GuitarBendGeometry.vertex(
                from: .zero, to: CGPoint(x: 100, y: 100), sp: sp, up: true,
            )
            let offset = 16.5 * CGFloat(sqrt(2.0) / 2.0)
            #expect(abs(v.x - (50 + offset)) < 0.01)
            #expect(abs(v.y - (50 - offset)) < 0.01)
        }

        @Test("a degenerate zero-length run stays finite and vertical")
        func degenerateRun() {
            // Pre-bends pair a note with itself, so `to == from`.
            // MuseScore's `-atan(Δy/Δx)` would be 0/0 = NaN here.
            let v = GuitarBendGeometry.vertex(
                from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5),
                sp: 10, up: true,
            )
            #expect(v.x.isFinite)
            #expect(v.y.isFinite)
            #expect(abs(v.x - 5) < 0.01)
            #expect(abs(v.y - -2.5) < 0.01) // 5 - 0.75sp
        }

        @Test("slight bend hook offsets are the MuseScore constants")
        func slightBendHook() {
            let sp: CGFloat = 12
            let end = GuitarBendGeometry.slightBendEnd(sp: sp)
            #expect(abs(end.x - 15) < 0.01) // 1.25sp
            #expect(abs(end.y - -12) < 0.01) // -1sp
            let control = GuitarBendGeometry.slightBendControl(sp: sp)
            #expect(abs(control.x - 15) < 0.01)
            #expect(abs(control.y) < 0.01)
        }

        @Test("line thickness matches the glissando rule")
        func lineThickness() {
            #expect(abs(GuitarBendGeometry.lineThicknessSp - 0.15) < 0.0001)
        }
    }

    /// End-to-end coverage of the collect → resolve → attach pass that
    /// turns `Note.guitarBend` into `LayoutElement.guitarBend` spanners.
    @Suite("Guitar bend layout pipeline")
    struct GuitarBendLayoutPipelineTests {
        private let _installApple = TestSupport.installApple

        /// Every `.guitarBend` spanner across all systems, in system order.
        private static func bends(
            in document: LayoutDocument,
        ) -> [(from: CGPoint, vertex: CGPoint, to: CGPoint, slight: Bool)] {
            document.systems.flatMap { system in
                system.spanners.compactMap { element in
                    guard case let .guitarBend(from, vertex, to, slight) = element
                    else { return nil }
                    return (from, vertex, to, slight)
                }
            }
        }

        @Test("plain bends produce guitarBend layout elements")
        func plainBendsEmit() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = try MSCXParser.parse(
                MSCXFixtureLoader.mscxData("guitarbend_simple"),
            )
            let document = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 1200,
            )
            let found = Self.bends(in: document)
            // The fixture carries three plain bends (see
            // `GuitarBendDecodeTests.simpleBends`); each pairs with the
            // next chord in the same voice, all on one system at this
            // width.
            #expect(found.count == 3)
            #expect(found.allSatisfy { !$0.slight })
            // Every bend runs left to right and its vertex sits between
            // the endpoints horizontally.
            #expect(found.allSatisfy { $0.to.x > $0.from.x })
            #expect(found.allSatisfy { $0.vertex.x > $0.from.x && $0.vertex.x < $0.to.x })
        }

        @Test("slight bends emit the fixed cubic hook")
        func slightBendsEmit() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = try MSCXParser.parse(
                MSCXFixtureLoader.mscxData("guitarbend_slightbend"),
            )
            let document = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 1200,
            )
            let found = Self.bends(in: document)
            #expect(found.count == 3)
            // `#expect` cannot expand a key path into `allSatisfy`'s
            // `rethrows` call; `found.count` is pinned above, so the
            // filter says the same thing.
            #expect(found.filter(\.slight).count == 3)
            let sp = document.metrics.sp
            for bend in found {
                #expect(abs((bend.to.x - bend.from.x) - sp * 1.25) < 0.01)
                #expect(abs((bend.to.y - bend.from.y) - -sp) < 0.01)
                #expect(abs((bend.vertex.x - bend.from.x) - sp * 1.25) < 0.01)
                #expect(abs(bend.vertex.y - bend.from.y) < 0.01)
            }
        }

        @Test("a bend's anchors sit 0.2sp off its noteheads' centres")
        func anchorsPinnedToNoteOrigins() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // The frame conversion this pins: MuseScore's note position is
            // the notehead's LEFT EDGE horizontally but its vertical
            // CENTRE, while ours is the centre on both axes. So the
            // `0.5 * width` term cancels horizontally (leaving ±0.2sp) and
            // the vertical `0.2sp + 0.5 * height` carries over whole. An
            // earlier revision kept the width term on both axes and pushed
            // each anchor a further 0.59sp outward — a green suite did not
            // catch it, because nothing compared an anchor to its note.
            let document = Self.twoNoteBendDocument(
                startPitch: 60, endPitch: 64,
            )
            let found = Self.bends(in: document)
            #expect(found.count == 1)
            let notes = Self.chordFirstNotes(in: document.systems[0].measures[0])
            #expect(notes.count == 2)
            guard let bend = found.first, notes.count == 2 else { return }
            let sp = document.metrics.sp
            let upSign: CGFloat = bend.vertex.y < bend.from.y ? -1 : 1
            let dy = upSign * sp * (0.2 + 1.0 / 2)
            #expect(abs(bend.from.x - (notes[0].origin.x + sp * 0.2)) < 0.01)
            #expect(abs(bend.from.y - (notes[0].origin.y + dy)) < 0.01)
            #expect(abs(bend.to.x - (notes[1].origin.x - sp * 0.2)) < 0.01)
            #expect(abs(bend.to.y - (notes[1].origin.y + dy)) < 0.01)
        }

        @Test("a slight bend's anchor sits half a notehead past its centre")
        func slightAnchorPinnedToNoteOrigin() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // The slight bend keeps its width term: MuseScore adds a FULL
            // notehead width to the left edge, which is half a width past
            // the centre.
            let a = Note(
                pitch: 60, tpc: 14,
                guitarBend: GuitarBend(type: .slightBend),
                guitarBendBack: true,
            )
            let measure = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [a])),
            ])])
            let document = Self.layout(measures: [measure])
            let found = Self.bends(in: document)
            #expect(found.count == 1)
            let notes = Self.chordFirstNotes(in: document.systems[0].measures[0])
            guard let bend = found.first, let note = notes.first else { return }
            let sp = document.metrics.sp
            #expect(abs(bend.from.x - (note.origin.x + sp * (1.18 / 2 + 0.25))) < 0.01)
            #expect(abs(bend.from.y - (note.origin.y - sp * 0.25)) < 0.01)
        }

        @Test("in a single voice the bend arcs opposite the start chord's stem")
        func bendOpposesStemDirection() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // MuseScore's `computeUp` never consults pitch — it takes the
            // opposite of the start chord's stem (`guitarbendlayout.cpp:253`,
            // `setUp(!startChord->up())`). Two registers so both stem
            // directions are exercised; the assertion is the RULE, read off
            // each document's own laid-out stem.
            var seen: Set<StemDirection> = []
            for startPitch in [50, 79] {
                let document = Self.twoNoteBendDocument(
                    startPitch: startPitch, endPitch: startPitch + 2,
                )
                let found = Self.bends(in: document)
                #expect(found.count == 1)
                let stems = Self.chordFirstNotes(
                    in: document.systems[0].measures[0],
                )
                guard let bend = found.first, let stem = stems.first?.stem
                else { continue }
                seen.insert(stem)
                let arcsUp = bend.vertex.y < bend.from.y
                #expect(arcsUp == (stem == .down))
            }
            // Non-vacuity: the two registers really did produce opposite
            // stems, so the assertion above was checked in both directions.
            #expect(seen == [.up, .down])
        }

        @Test("in a multi-voice measure the bend follows track parity")
        func bendFollowsTrackParityWhenVoicesShareAMeasure() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // C++: `if (measure->hasVoices(staffIdx)) { setUp(track() % 2); }`
            // (`guitarbendlayout.cpp:237-238`). `track % 2` is 0 for voice
            // 0, so voice 0 → arcs DOWN, voice 1 → arcs UP.
            for (bendVoice, expectUp) in [(0, false), (1, true)] {
                let document = Self.multiVoiceBendDocument(bendVoice: bendVoice)
                let found = Self.bends(in: document)
                #expect(found.count == 1)
                guard let bend = found.first else { continue }
                #expect((bend.vertex.y < bend.from.y) == expectUp)
            }
        }

        @Test("bendIsUp falls back to up when no stem is known")
        func bendIsUpFallback() {
            let id = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 0,
                noteIndexInChord: 0,
            )
            let pairing = LayoutEngine.GuitarBendPairing(
                from: id, to: id, sameNote: true,
                multiVoice: false, slight: false,
            )
            // Hand-built systems carry no `.chord` elements, so the stem
            // map comes back empty — the neutral branch.
            #expect(LayoutEngine.bendIsUp(pairing: pairing, stems: [:]))
            #expect(!LayoutEngine.bendIsUp(pairing: pairing, stems: [id: .up]))
            #expect(LayoutEngine.bendIsUp(pairing: pairing, stems: [id: .down]))
        }

        @Test("a bend whose next chord is not a bend destination is dropped")
        func bendWithoutMarkedTargetIsDropped() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // The decoder stamps `guitarBendBack` on genuine destinations.
            // When the next real chord carries none, this bend's true
            // target is something the walk can't see (in practice a grace
            // chord), so pairing with it would draw to the wrong notehead.
            let a = Note(
                pitch: 60, tpc: 14, guitarBend: GuitarBend(type: .bend),
            )
            let b = Note(pitch: 64, tpc: 14) // NOT a bend destination
            let measure = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [a])),
                .chord(Chord(duration: .quarter, notes: [b])),
            ])])
            let document = Self.layout(measures: [measure])
            #expect(Self.bends(in: document).isEmpty)
        }

        @Test("whammy-bar bend types are not laid out in v1")
        func whammyTypesSkipped() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            for type in [
                GuitarBendType.dive, .preDive, .dip, .scoop,
            ] {
                let document = Self.twoNoteBendDocument(
                    startPitch: 60, endPitch: 64, type: type,
                )
                #expect(Self.bends(in: document).isEmpty)
            }
        }

        /// First-note origin (SYSTEM-local, matching the frame spanners
        /// use) and owning chord's stem direction, for every real chord in
        /// `measure`, in element order.
        private static func chordFirstNotes(
            in measure: LayoutMeasure,
        ) -> [(origin: CGPoint, stem: StemDirection)] {
            measure.elements.compactMap { el in
                guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = el,
                      let n = notes.first
                else { return nil }
                return (
                    CGPoint(
                        x: measure.origin.x + n.origin.x,
                        y: measure.origin.y + n.origin.y,
                    ),
                    stem,
                )
            }
        }

        private static func layout(measures: [Measure]) -> LayoutDocument {
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
            )
            return LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
        }

        /// Two quarter chords in one measure, the first carrying a bend
        /// into the second.
        private static func twoNoteBendDocument(
            startPitch: Int,
            endPitch: Int,
            type: GuitarBendType = .bend,
        ) -> LayoutDocument {
            let a = Note(
                pitch: startPitch, tpc: 14,
                guitarBend: GuitarBend(type: type),
            )
            let b = Note(pitch: endPitch, tpc: 14, guitarBendBack: true)
            return layout(measures: [Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [a])),
                .chord(Chord(duration: .quarter, notes: [b])),
            ])])])
        }

        /// One measure with TWO voices carrying content (so MuseScore's
        /// `measure->hasVoices` is true), the bend on `bendVoice` only.
        private static func multiVoiceBendDocument(
            bendVoice: Int,
        ) -> LayoutDocument {
            func voice(bent: Bool, pitch: Int) -> Voice {
                let a = Note(
                    pitch: pitch, tpc: 14,
                    guitarBend: bent ? GuitarBend(type: .bend) : nil,
                )
                let b = Note(
                    pitch: pitch + 2, tpc: 14, guitarBendBack: bent,
                )
                return Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: [a])),
                    .chord(Chord(duration: .quarter, notes: [b])),
                ])
            }
            return layout(measures: [Measure(voices: [
                voice(bent: bendVoice == 0, pitch: 72),
                voice(bent: bendVoice == 1, pitch: 52),
            ])])
        }
    }
#endif
