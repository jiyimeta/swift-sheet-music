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

        @Test("a rising bend arcs above and a falling bend arcs below")
        func bendDirectionFollowsPitch() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let up = Self.twoNoteBendDocument(startPitch: 60, endPitch: 64)
            let down = Self.twoNoteBendDocument(startPitch: 64, endPitch: 60)
            let upBends = Self.bends(in: up)
            let downBends = Self.bends(in: down)
            #expect(upBends.count == 1)
            #expect(downBends.count == 1)
            guard let u = upBends.first, let d = downBends.first else { return }
            // `up` puts the vertex above the chord of the two anchors,
            // `down` below it (y grows downward).
            #expect(u.vertex.y < min(u.from.y, u.to.y))
            #expect(d.vertex.y > max(d.from.y, d.to.y))
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
            let measure = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [a])),
                .chord(Chord(duration: .quarter, notes: [b])),
            ])])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [measure])],
                )],
            )
            return LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
        }
    }
#endif
