#if os(macOS)
    import SheetMusicCore
    import SheetMusicLayout
    import SwiftUI

    /// User-facing clef choices in the macOS example. Mirrors the set
    /// `NotatedClef` understands; the library still accepts any raw clef
    /// string via `Clef(concertClefType:)`.
    enum ClefChoice: Hashable, CaseIterable {
        case trebleG15ma, trebleG8va, trebleG, trebleG8vb, trebleG15mb
        case bassF8va, bassF, bassF8vb
        case sopranoC1, altoC3, tenorC4, baritoneC5
        case percussion, percussion2

        var rawType: String {
            switch self {
            case .trebleG15ma: "G15ma"
            case .trebleG8va: "G8va"
            case .trebleG: "G"
            case .trebleG8vb: "G8vb"
            case .trebleG15mb: "G15mb"
            case .bassF8va: "F8va"
            case .bassF: "F"
            case .bassF8vb: "F8vb"
            case .sopranoC1: "C1"
            case .altoC3: "C3"
            case .tenorC4: "C4"
            case .baritoneC5: "C5"
            case .percussion: "PERC"
            case .percussion2: "PERC2"
            }
        }

        /// SMuFL Private Use Area codepoints, hard-coded because
        /// `SheetMusicUI.SMuFLGlyph` is internal. Stable per the SMuFL spec
        /// (https://www.smufl.org/version/latest/range/clefs/).
        var smuflGlyph: Character {
            switch self {
            case .trebleG: "\u{E050}" // gClef
            case .trebleG15mb: "\u{E051}" // gClef15mb
            case .trebleG8vb: "\u{E052}" // gClef8vb
            case .trebleG8va: "\u{E053}" // gClef8va
            case .trebleG15ma: "\u{E054}" // gClef15ma
            case .bassF: "\u{E062}" // fClef
            case .bassF8vb: "\u{E064}" // fClef8vb
            case .bassF8va: "\u{E065}" // fClef8va
            case .sopranoC1, .altoC3, .tenorC4, .baritoneC5: "\u{E05C}" // cClef
            case .percussion: "\u{E069}" // unpitchedPercussionClef1
            case .percussion2: "\u{E06A}" // unpitchedPercussionClef2
            }
        }

        /// Vertical offset (in spatium units) from the middle staff line
        /// to the glyph's center, matching `ClefRenderer.draw`'s switch
        /// in SheetMusicUI. Positive = downward.
        var staffOffsetSp: CGFloat {
            switch self {
            case .trebleG, .trebleG8va, .trebleG8vb, .trebleG15ma, .trebleG15mb:
                return 1 // gClef sits on line 2 (one line below middle)
            case .bassF, .bassF8va, .bassF8vb:
                return -1 // fClef sits on line 4 (one line above middle)
            case .sopranoC1: return 2 // bottom line
            case .altoC3: return 0 // middle line
            case .tenorC4: return -1 // line 4
            case .baritoneC5: return -2 // top line
            case .percussion, .percussion2: return 0
            }
        }

        static func from(rawType: String) -> ClefChoice? {
            ClefChoice.allCases.first { $0.rawType == rawType }
        }
    }

    /// Grouped clef-picker popover. Each tile renders a mini 5-line
    /// staff with the clef glyph at its canonical position so all four
    /// C-clef variants (which share the cClef glyph) are visually
    /// distinct. Library types stay format-agnostic — this view is a
    /// host-side UI choice.
    struct ClefPopover: View {
        let current: ClefChoice?
        let onPick: (ClefChoice) -> Void

        var body: some View {
            VStack(spacing: 6) {
                row([.trebleG15ma, .trebleG8va, .trebleG, .trebleG8vb, .trebleG15mb])
                row([.bassF8va, .bassF, .bassF8vb])
                row([.sopranoC1, .altoC3, .tenorC4, .baritoneC5])
                row([.percussion, .percussion2])
            }
            .padding(12)
        }

        private func row(_ choices: [ClefChoice]) -> some View {
            HStack(spacing: 6) {
                ForEach(choices, id: \.self) { button(for: $0) }
            }
        }

        private func button(for choice: ClefChoice) -> some View {
            Button { onPick(choice) } label: {
                ClefTile(choice: choice, isSelected: choice == current)
                    // Without this, `.buttonStyle(.plain)` hit-tests
                    // only the visible ink, leaving most of the tile
                    // non-clickable.
                        .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(choice.rawType)
        }
    }

    /// One picker tile: mini 5-line staff + clef glyph at the canonical
    /// y position. Spatium is fixed at 4pt — large enough that the
    /// 8va/15ma annotations on octave-displaced glyphs remain legible.
    private struct ClefTile: View {
        let choice: ClefChoice
        let isSelected: Bool

        private let tileSize = CGSize(width: 56, height: 56)
        private let spatium: CGFloat = 4
        private let glyphSize: CGFloat = 26

        var body: some View {
            Canvas { context, size in
                let midY = size.height / 2
                drawStaff(in: &context, midY: midY, width: size.width)
                drawGlyph(in: &context, midY: midY, width: size.width)
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear,
                    ),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected
                            ? Color.accentColor
                            : Color.gray.opacity(0.3),
                        lineWidth: isSelected ? 2 : 1,
                    ),
            )
        }

        private func drawStaff(
            in context: inout GraphicsContext,
            midY: CGFloat, width: CGFloat,
        ) {
            let inset: CGFloat = 6
            for line in -2 ... 2 {
                let y = midY + CGFloat(line) * spatium
                var path = Path()
                path.move(to: CGPoint(x: inset, y: y))
                path.addLine(to: CGPoint(x: width - inset, y: y))
                context.stroke(
                    path,
                    with: .color(.primary.opacity(0.55)),
                    lineWidth: 0.6,
                )
            }
        }

        private func drawGlyph(
            in context: inout GraphicsContext,
            midY: CGFloat, width: CGFloat,
        ) {
            let glyphY = midY + choice.staffOffsetSp * spatium
            let text = Text(String(choice.smuflGlyph))
                .font(.custom(BravuraFont.familyName, size: glyphSize))
                .foregroundStyle(Color.primary)
            let resolved = context.resolve(text)
            context.draw(
                resolved,
                at: CGPoint(x: width / 2, y: glyphY),
                anchor: .center,
            )
        }
    }
#endif
