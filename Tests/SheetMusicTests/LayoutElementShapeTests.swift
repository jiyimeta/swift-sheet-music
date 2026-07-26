#if !os(Android)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("LayoutElementShape base skyline")
    struct LayoutElementShapeTests {
        private let _installApple = TestSupport.installApple
        private let metrics = StaffMetrics(staffSize: 28) // sp = 7

        private func note(step: Int, y: CGFloat) -> LayoutChordNote {
            LayoutChordNote(
                noteID: NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: 0, voiceIndex: 0,
                    elementIndex: 0, noteIndexInChord: 0,
                ),
                step: step, accidental: nil,
                origin: CGPoint(x: 40, y: y),
                tieForward: nil, tieBack: nil, hasGlissando: false,
            )
        }

        @Test func kindMapsChordAndExcludesStaffName() {
            let chord = LayoutElement.chord(
                notes: [note(step: 0, y: 14)], duration: .quarter,
                stem: .up, stemOrigin: CGPoint(x: 40, y: 14),
                hasArpeggio: false, arpeggioRawType: nil,
                isBeamed: false, voiceIndex: 0, stemExtension: 0,
                stemIsInvisible: false, mag: 1,
            )
            #expect(LayoutElementShape.kind(of: chord) == .chord)
            #expect(LayoutElementShape.kind(of: .staffName(
                text: "Vln", origin: .zero,
            )) == nil)
            #expect(LayoutElementShape.kind(of: .spannerSegment(
                kind: .slur, fromOrigin: .zero, toOrigin: .zero,
                continuesLeft: false, continuesRight: false, text: "",
            )) == nil)
            #expect(LayoutElementShape.kind(of: .spannerSegment(
                kind: .vibrato(.guitarVibrato),
                fromOrigin: .zero, toOrigin: .zero,
                continuesLeft: false, continuesRight: false, text: "",
            )) == nil)
        }

        /// A stem-up chord's shape must reach from the stem tip
        /// (3.5 sp above the lowest notehead) down past the notehead.
        @Test func stemUpChordShapeCoversStemTip() throws {
            let chord = LayoutElement.chord(
                notes: [note(step: 0, y: 14)], duration: .quarter,
                stem: .up, stemOrigin: CGPoint(x: 40, y: 14),
                hasArpeggio: false, arpeggioRawType: nil,
                isBeamed: false, voiceIndex: 0, stemExtension: 0,
                stemIsInvisible: false, mag: 1,
            )
            let shape = try #require(LayoutElementShape.shape(
                for: chord, id: 0, xOffset: 100, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            // Stem tip: 14 − 3.5 sp = 14 − 24.5 = −10.5.
            #expect(abs(box.minY - -10.5) < 0.01)
            // Notehead bottom: 14 + 0.5 sp = 17.5.
            #expect(box.maxY >= 17.5)
            // xOffset applied.
            #expect(box.minX > 100)
        }

        /// Stem-down mirrors it.
        @Test func stemDownChordShapeCoversStemTip() throws {
            let chord = LayoutElement.chord(
                notes: [note(step: 0, y: 14)], duration: .quarter,
                stem: .down, stemOrigin: CGPoint(x: 40, y: 14),
                hasArpeggio: false, arpeggioRawType: nil,
                isBeamed: false, voiceIndex: 0, stemExtension: 0,
                stemIsInvisible: false, mag: 1,
            )
            let shape = try #require(LayoutElementShape.shape(
                for: chord, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(abs(box.maxY - 38.5) < 0.01) // 14 + 24.5
        }

        /// An above-arcing tie extends the shape past the notehead.
        @Test func aboveTieExtendsChordShapeUpward() throws {
            var tied = note(step: 0, y: 14)
            tied = LayoutChordNote(
                noteID: tied.noteID, step: 0, accidental: nil,
                origin: tied.origin, tieForward: 1, tieBack: nil,
                hasGlissando: false,
            )
            let chord = LayoutElement.chord(
                notes: [tied], duration: .quarter,
                stem: .down, stemOrigin: CGPoint(x: 40, y: 14),
                hasArpeggio: false, arpeggioRawType: nil,
                isBeamed: false, voiceIndex: 0, stemExtension: 0,
                stemIsInvisible: false, mag: 1,
            )
            let shape = try #require(LayoutElementShape.shape(
                for: chord, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            // Tie apex: 14 − 1.6 sp = 14 − 11.2 = 2.8.
            #expect(box.minY <= 2.9)
        }

        /// `relativeX` is already baked into a grace chord's note and
        /// stem origins, so the shape must sit at those coordinates —
        /// not at a further offset from them.
        @Test func graceChordShapeDoesNotReapplyRelativeX() throws {
            let relativeX: CGFloat = -10.5
            let grace = LayoutElement.graceChord(
                notes: [note(step: 0, y: 14)], duration: .eighth,
                stem: .up, stemOrigin: CGPoint(x: 40, y: 14),
                relativeX: relativeX, hasSlash: false, mag: 0.7,
                voiceIndex: 0,
            )
            let shape = try #require(LayoutElementShape.shape(
                for: grace, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            // Notehead is 1.18 sp × mag wide, centered on x = 40.
            let halfWidth = metrics.sp * 1.18 * 0.7 / 2
            #expect(abs(box.minX - (40 - halfWidth)) < 0.01)
            #expect(abs(box.maxX - (40 + halfWidth)) < 0.01)
        }

        @Test func beamShapeSpansBothEndpoints() throws {
            let beam = LayoutElement.beam(
                fromOrigin: CGPoint(x: 10, y: -5),
                toOrigin: CGPoint(x: 60, y: -12),
                direction: .up, level: 1,
            )
            let shape = try #require(LayoutElementShape.shape(
                for: beam, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(box.minX == 10)
            #expect(box.maxX == 60)
            #expect(box.minY < -12)
            #expect(box.maxY > -5)
        }

        @Test func fermataShapeHasPositiveArea() throws {
            let fermata = LayoutElement.fermata(
                subtype: "fermataAbove", origin: CGPoint(x: 40, y: 0),
            )
            let shape = try #require(LayoutElementShape.shape(
                for: fermata, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(box.width > 0)
            #expect(box.height > 0)
        }

        @Test func staffRectSpansTheStaffHeight() {
            let r = LayoutElementShape.staffRect(
                xMin: 0, xMax: 500, staffMidY: 28, metrics: metrics,
            )
            #expect(r.item.kind == .staff)
            #expect(r.rect.minY == 14) // staffMidY − 2 sp
            #expect(r.rect.maxY == 42) // staffMidY + 2 sp
            #expect(r.rect.width == 500)
        }
    }

    @Suite("LayoutElementShape autoplaced elements")
    struct LayoutElementAutoplacedShapeTests {
        private let _installApple = TestSupport.installApple
        private let metrics = StaffMetrics(staffSize: 28) // sp = 7

        /// A long rehearsal mark must produce a WIDER rect than a short
        /// one — the character-count estimate this replaces got CJK and
        /// wide labels badly wrong.
        @Test func rehearsalMarkWidthTracksMeasuredText() throws {
            func width(_ text: String) throws -> CGFloat {
                let el = LayoutElement.rehearsalMark(
                    text: text, origin: CGPoint(x: 0, y: 0),
                    frame: .rectangle, color: nil,
                )
                let shape = try #require(LayoutElementShape.shape(
                    for: el, id: 0, xOffset: 0, metrics: metrics,
                ))
                return try #require(shape.bbox).width
            }
            #expect(try width("A") < width("Chorus 1"))
            #expect(try width("A") > 0)
        }

        /// The frame padding is included, so a framed mark is wider and
        /// taller than an unframed one with the same text.
        @Test func rehearsalMarkFrameAddsPadding() throws {
            func box(_ frame: RehearsalMark.FrameKind) throws -> CGRect {
                let el = LayoutElement.rehearsalMark(
                    text: "A", origin: CGPoint(x: 0, y: 0),
                    frame: frame, color: nil,
                )
                let shape = try #require(LayoutElementShape.shape(
                    for: el, id: 0, xOffset: 0, metrics: metrics,
                ))
                return try #require(shape.bbox)
            }
            let plain = try box(.none)
            let framed = try box(.rectangle)
            #expect(framed.width > plain.width)
            #expect(framed.height > plain.height)
        }

        /// `.bottomLeading` anchor: the rect sits ABOVE origin.y and
        /// starts AT origin.x.
        @Test func bottomLeadingAnchorPlacesRectAboveOrigin() throws {
            let el = LayoutElement.staffText(
                text: "dolce", origin: CGPoint(x: 30, y: 10),
                color: nil, isSystemText: false,
            )
            let shape = try #require(LayoutElementShape.shape(
                for: el, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(abs(box.maxY - 10) < 0.01)
            #expect(abs(box.minX - 30) < 0.01)
        }

        /// `.center` anchor (lyrics): the rect straddles origin on both
        /// axes.
        @Test func centerAnchorStraddlesOrigin() throws {
            let el = LayoutElement.textMark(
                kind: .lyrics(color: nil), text: "sing",
                origin: CGPoint(x: 50, y: 60),
            )
            let shape = try #require(LayoutElementShape.shape(
                for: el, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(box.minX < 50 && box.maxX > 50)
            #expect(box.minY < 60 && box.maxY > 60)
        }

        /// `.leadingCenter` anchor (tempo): starts at origin.x,
        /// straddles origin.y, and the Bravura beat glyph counts
        /// toward the width.
        @Test func tempoRectUsesMixedRunWidths() throws {
            let el = LayoutElement.textMark(
                kind: .tempo, text: "\u{E1D5} = 120",
                origin: CGPoint(x: 20, y: -14),
            )
            let shape = try #require(LayoutElementShape.shape(
                for: el, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(abs(box.minX - 20) < 0.01)
            #expect(box.minY < -14 && box.maxY > -14)
            #expect(box.width > metrics.sp * 3)
        }

        @Test func harmonyRectUsesItsPrecomputedWidth() throws {
            let harmony = Harmony(name: "C", rootTpc: 14)
            let lh = LayoutHarmony(
                harmony: harmony, anchorX: 40, y: -18,
                runs: [], width: 33,
            )
            let shape = try #require(LayoutElementShape.shape(
                for: .harmony(lh), id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(abs(box.width - 33) < 0.01)
            #expect(abs(box.minX - 40) < 0.01)
        }

        /// A dynamic's rect is its GLYPH INK, never Bravura's em box.
        ///
        /// Bravura reserves 2 em of ascent and 2 em of descent so that
        /// staff-relative glyphs fit inside one line box, so at the
        /// 4 sp dynamics size the em box is 16.1 sp tall against the
        /// 2.4 sp `mf` actually inks. The corpus scan caught it:
        /// a single `mf` claimed 8 sp of skyline above AND below its
        /// own origin and collided with the neighbouring staff's text.
        @Test func dynamicRectIsGlyphInkNotTheBravuraEmBox() throws {
            let el = LayoutElement.textMark(
                kind: .dynamic, text: "mf",
                origin: CGPoint(x: 10, y: 40),
            )
            let shape = try #require(LayoutElementShape.shape(
                for: el, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(abs(box.minX - 10) < 0.01)
            #expect(box.width > 0)
            // Ink (≈ 2.4 sp), not the 16.1 sp em box.
            #expect(box.height > metrics.sp * 0.5)
            #expect(box.height < metrics.sp * 4)
            // Pin the POSITION, not just the height: a band of the
            // right size measured off the wrong baseline would pass a
            // height-only check. A `.leadingCenter` anchor on a face
            // whose ascent equals its descent puts the baseline exactly
            // on origin.y, and `mf` inks 1.8 sp above it, with
            // Bravura's calligraphic `f` reaching 0.6 sp below.
            #expect(abs(box.minY - (40 - metrics.sp * 1.8)) < 0.5)
            #expect(abs(box.maxY - (40 + metrics.sp * 0.61)) < 0.5)
        }

        /// Tempo mixes an Edwin run with a Bravura beat glyph, so the
        /// same em-box trap applies to its glyph half: the union must
        /// use the glyph's measured ink, not Bravura's 4 em line box.
        ///
        /// And it must place that ink the way `ScoreLayerBuilder` draws
        /// it — `bravuraInkCenteredLayer` centres the glyph's INK on
        /// `origin.y`. Offsetting it by the Edwin run's baseline (which
        /// sits 3.98 pt below `origin.y` at this size) instead put the
        /// band 0.57 sp off, more than the pass's whole 0.5 sp
        /// `minVerticalDistance` budget — and a height-only assertion
        /// could not see it. Hence the explicit min/max Y below.
        @Test func tempoRectDoesNotInheritTheBravuraEmBox() throws {
            let el = LayoutElement.textMark(
                kind: .tempo, text: "\u{E1D5} = 120",
                origin: CGPoint(x: 20, y: -14),
            )
            let shape = try #require(LayoutElementShape.shape(
                for: el, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            // The beat glyph reaches below the Edwin run's own
            // descent, so the union is taller than the text box…
            #expect(box.height > metrics.sp * 2)
            // …but nowhere near Bravura's 4 em (≈ 9.7 sp here).
            #expect(box.height < metrics.sp * 5)
            // Both the Edwin box and the glyph ink are centred on
            // `origin.y`, so their union is too — exactly.
            #expect(abs((box.minY + box.maxY) / 2 - -14) < 0.01)
            #expect(abs(box.minY - (-14 - metrics.sp * 1.22)) < 0.5)
            #expect(abs(box.maxY - (-14 + metrics.sp * 1.22)) < 0.5)
        }

        @Test func melismaAndHyphenAreThinSpans() throws {
            let melisma = LayoutElement.lyricsMelisma(
                fromOrigin: CGPoint(x: 10, y: 70),
                toOrigin: CGPoint(x: 90, y: 70),
            )
            let shape = try #require(LayoutElementShape.shape(
                for: melisma, id: 0, xOffset: 0, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(box.width == 80)
            #expect(box.height > 0 && box.height < metrics.sp)
        }

        @Test func hairpinSpanCoversBothEndpoints() throws {
            let hairpin = LayoutElement.spannerSegment(
                kind: .hairpinOpen,
                fromOrigin: CGPoint(x: 10, y: 60),
                toOrigin: CGPoint(x: 100, y: 60),
                continuesLeft: false, continuesRight: false, text: "",
            )
            let shape = try #require(LayoutElementShape.shape(
                for: hairpin, id: 0, xOffset: 5, metrics: metrics,
            ))
            let box = try #require(shape.bbox)
            #expect(box.minX == 15)
            #expect(box.maxX == 105)
            #expect(box.height > 0)
        }
    }
#endif
