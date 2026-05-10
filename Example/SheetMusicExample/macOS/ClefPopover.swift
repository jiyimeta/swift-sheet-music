#if os(macOS)
    import SheetMusicLayout
    import SwiftUI

    /// The four user-facing clef choices in the macOS example.
    /// The library still accepts any raw clef string via
    /// `Clef(concertClefType:)`; this enum just constrains the UI.
    enum ClefChoice: Hashable, CaseIterable {
        case trebleG, trebleG8vb, bassF, bassF8vb

        var rawType: String {
            switch self {
            case .trebleG: "G"
            case .trebleG8vb: "G8vb"
            case .bassF: "F"
            case .bassF8vb: "F8vb"
            }
        }

        /// SMuFL Private Use Area codepoints from
        /// https://www.smufl.org/version/latest/range/clefs/
        /// Hard-coded here because `SheetMusicUI.SMuFLGlyph` is
        /// internal; the codepoints are stable in the SMuFL standard.
        var smuflGlyph: Character {
            switch self {
            case .trebleG: return "\u{E050}" // gClef
            case .trebleG8vb: return "\u{E052}" // gClef8vb
            case .bassF: return "\u{E062}" // fClef
            case .bassF8vb: return "\u{E064}" // fClef8vb
            }
        }

        static func from(rawType: String) -> ClefChoice? {
            ClefChoice.allCases.first { $0.rawType == rawType }
        }
    }

    /// 2×2 grid of clef glyph buttons used by the macOS example to
    /// replace a tapped clef. Library-level types stay format-agnostic
    /// — this view is a host-side UI choice.
    struct ClefPopover: View {
        let current: ClefChoice?
        let onPick: (ClefChoice) -> Void

        var body: some View {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    button(for: .trebleG)
                    button(for: .trebleG8vb)
                }
                HStack(spacing: 8) {
                    button(for: .bassF)
                    button(for: .bassF8vb)
                }
            }
            .padding(12)
            .frame(width: 160)
        }

        @ViewBuilder
        private func button(for choice: ClefChoice) -> some View {
            Button { onPick(choice) } label: {
                Text(String(choice.smuflGlyph))
                    .font(.custom(BravuraFont.familyName, size: 36))
                    .frame(width: 60, height: 60)
                    .background(
                        choice == current
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                choice == current
                                    ? Color.accentColor
                                    : Color.gray.opacity(0.3),
                                lineWidth: choice == current ? 2 : 1
                            ))
            }
            .buttonStyle(.plain)
            .help(choice.rawType)
        }
    }
#endif
