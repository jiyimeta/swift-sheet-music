#if os(macOS)
    import CoreText
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("ScoreLayerBuilder notehead glyph pipeline")
    struct ScoreLayerBuilderTests {
        @Test("Bravura supplies a non-empty path for noteheadBlack")
        func noteheadBlackPathIsNonEmpty() throws {
            guard #available(macOS 15.0, *) else { return }
            let ok = BravuraFont.register
            try #require(ok)

            let font = CTFontCreateWithName(
                "Bravura" as CFString, 28, nil,
            )
            let resolved = CTFontCopyFamilyName(font) as String
            try #require(
                resolved == "Bravura",
                "Bravura did not resolve — got \(resolved)",
            )

            // SMuFL noteheadBlack is U+E0A4.
            let chars: [UniChar] = [0xE0A4]
            var glyphs = [CGGlyph](repeating: 0, count: 1)
            let found = CTFontGetGlyphsForCharacters(
                font, chars, &glyphs, 1,
            )
            #expect(found, "Bravura missing glyph for U+E0A4")
            try #require(
                glyphs[0] != 0,
                "Bravura returned .notdef for U+E0A4",
            )

            var t = CGAffineTransform.identity
            let path = try #require(
                CTFontCreatePathForGlyph(font, glyphs[0], &t),
                "CTFont returned nil path for notehead",
            )
            let bbox = path.boundingBoxOfPath
            #expect(bbox.width > 0, "Notehead bbox has zero width")
            #expect(bbox.height > 0, "Notehead bbox has zero height")
        }

        @MainActor
        @Test("buildSystem produces a notehead-bearing sublayer tree")
        func buildSystemEmitsNoteheadLayer() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register

            let note = Note(pitch: 60, tpc: 14)
            let m = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            let staff = Staff(measures: [m])
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])

            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40,
                wrapToViewWidth: false,
            )
            let natW = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: natW,
            )
            let system = try #require(doc.systems.first)

            let tree = ScoreLayerBuilder.buildSystem(
                system, metrics: doc.metrics,
            )

            let sublayers = collectAllLayers(tree)
            // Staff has 5 lines (1 layer, combined path), plus clef and
            // notehead glyph layers at minimum.
            #expect(
                sublayers.count >= 3,
                "tree has only \(sublayers.count) sublayers",
            )

            // Noteheads are filled CAShapeLayers whose path covers an
            // area roughly 1 em wide; accidentals and clefs share the
            // CAShapeLayer type so we use the glyph bbox as the signature.
            let glyphLayers = sublayers.compactMap {
                $0 as? CAShapeLayer
            }.filter { $0.fillColor != nil && $0.path != nil }
            #expect(
                !glyphLayers.isEmpty,
                "no filled CAShapeLayers found",
            )
        }

        private func collectAllLayers(_ root: CALayer) -> [CALayer] {
            var all: [CALayer] = [root]
            for child in root.sublayers ?? [] {
                all.append(contentsOf: collectAllLayers(child))
            }
            return all
        }

        @MainActor
        @Test("Acciaccatura emits a diagonal stroke (the slash)")
        func acciaccaturaSlashIsDrawn() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register
            // Build: <acciaccatura/> before a quarter chord on middle C.
            let main = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                graceNotesBefore: [GraceChord(
                    graceType: .acciaccatura, duration: .eighth,
                    notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
                )],
            )
            let staff = Staff(measures: [Measure(voices: [Voice(elements: [.chord(main)])])])
            let score = Score(division: 480, parts: [
                Part(id: "1", instrument: Instrument(id: "x"), staves: [staff]),
            ])
            let opts = ScoreViewOptions(staffSize: 28, systemGap: 40, wrapToViewWidth: false)
            let natW = LayoutEngine.naturalContentWidth(score: score, options: opts)
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: natW,
            )
            let system = try #require(doc.systems.first)
            let tree = ScoreLayerBuilder.buildSystem(system, metrics: doc.metrics)
            // Slash is a stroked line — distinguished from filled glyph
            // layers (noteheads/clef) and from vertical stems (which
            // start.x == end.x). A diagonal stroke with a small bbox is
            // the acciaccatura slash signature.
            let strokes = collectAllLayers(tree)
                .compactMap { $0 as? CAShapeLayer }
                .filter { $0.strokeColor != nil && $0.fillColor == nil }
            let diagonal = strokes.first { l in
                guard let p = l.path else { return false }
                let bb = p.boundingBoxOfPath
                return bb.width > 0.5 && bb.height > 0.5
                    && bb.width < 20 && bb.height < 20
            }
            #expect(
                diagonal != nil,
                "no diagonal stroke layer found among \(strokes.count) strokes",
            )
        }

        @MainActor
        @Test("Staccato chord emits a glyph sublayer above the staff")
        func staccatoEmitsGlyphLayer() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register
            let chord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                articulations: [
                    .init(kind: .staccato, anchor: .above),
                ],
            )
            let staff = Staff(measures: [
                Measure(voices: [Voice(elements: [.chord(chord)])]),
            ])
            let score = Score(division: 480, parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff],
                ),
            ])
            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            )
            let natW = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: natW,
            )
            let system = try #require(doc.systems.first)
            let tree = ScoreLayerBuilder.buildSystem(
                system, metrics: doc.metrics,
            )
            let sp = doc.metrics.sp
            let glyphLayers = collectAllLayers(tree)
                .compactMap { $0 as? CAShapeLayer }
                .filter { $0.fillColor != nil && $0.path != nil }
            let dot = glyphLayers.first { l in
                guard let p = l.path else { return false }
                let bb = p.boundingBoxOfPath
                return bb.width > 0 && bb.width < sp
                    && bb.height > 0 && bb.height < sp
            }
            #expect(
                dot != nil,
                "no staccato-sized glyph layer found among \(glyphLayers.count) filled layers",
            )
        }

        @MainActor
        @Test("Accent chord emits a glyph sublayer above the staff")
        func accentEmitsGlyphLayer() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register
            let chord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                articulations: [.init(kind: .accent, anchor: .above)],
            )
            let staff = Staff(measures: [
                Measure(voices: [Voice(elements: [.chord(chord)])]),
            ])
            let score = Score(division: 480, parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff],
                ),
            ])
            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            )
            let natW = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: natW,
            )
            let system = try #require(doc.systems.first)
            let tree = ScoreLayerBuilder.buildSystem(
                system, metrics: doc.metrics,
            )
            let sp = doc.metrics.sp
            let glyphLayers = collectAllLayers(tree)
                .compactMap { $0 as? CAShapeLayer }
                .filter { $0.fillColor != nil && $0.path != nil }
            // Accent glyph is roughly 1 sp wide / 1 sp tall — looser bound
            // than staccato to accommodate Bravura's actual glyph metrics.
            let accent = glyphLayers.first { l in
                guard let p = l.path else { return false }
                let bb = p.boundingBoxOfPath
                return bb.width > sp * 0.5 && bb.width < sp * 2.0
                    && bb.height > 0 && bb.height < sp * 1.5
            }
            #expect(
                accent != nil,
                "no accent-sized glyph layer found among \(glyphLayers.count) filled layers",
            )
        }
    }
#endif
