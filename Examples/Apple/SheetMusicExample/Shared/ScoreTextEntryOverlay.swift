import Foundation
import SheetMusic
import SheetMusicUI
import SwiftUI

/// Identity that rebuilds the inline editor when the caret moves between
/// anchors, kinds, or lyric verses. On macOS it additionally travels through
/// the AppKit-hosted score container, whose NSScrollView breaks the SwiftUI
/// hierarchy; the iOS viewport composes the overlay directly.
enum ScoreTextEntryOverlayIdentity: Hashable {
    case lyric(LyricInputPlanner.Cursor)
    case text(kind: Int, anchor: VoiceElementID)
}

extension TextInputPlanner.Kind {
    var overlayIdentity: Int {
        switch self {
        case .staffText: 0
        case .systemText: 1
        case .chordSymbol: 2
        case .rehearsalMark: 3
        }
    }
}

/// Inline text field positioned in the score document's coordinate space.
@available(macOS 15.0, *)
struct ScoreTextEntryOverlay: View {
    enum Role {
        case lyric
        case text(TextInputPlanner.Kind)

        var isHorizontallyCentered: Bool {
            if case .lyric = self { true } else { false }
        }

        var textStyle: TextStyleType {
            switch self {
            case .lyric:
                return .lyricsOdd
            case let .text(kind):
                switch kind {
                case .staffText:
                    return .staffText
                case .systemText:
                    return .systemText
                case .chordSymbol:
                    // The editor writes standard harmonies, so this
                    // matches everything it creates. Re-editing an
                    // imported Roman-numeral harmony remains an
                    // approximation: its renderer uses Campania via
                    // `.chordSymbolRomanNumeral` instead.
                    return .chordSymbolA
                case .rehearsalMark:
                    return .rehearsalMark
                }
            }
        }
    }

    let document: LayoutDocument
    let origin: CGPoint
    let role: Role
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if case .text(.rehearsalMark) = role,
               text.isEmpty
            {
                RehearsalMarkEditingFrame(
                    textOrigin: origin,
                    sp: document.metrics.sp,
                )
            }
            inputField.position(
                x: inputFieldCenter.x,
                y: inputFieldCenter.y,
            )
        }
        .frame(
            width: document.size.width,
            height: document.size.height,
            alignment: .topLeading,
        )
    }

    private var inputFieldCenter: CGPoint {
        guard case let .text(kind) = role else { return origin }
        let font = EngravedTextFieldFont(
            style: role.textStyle,
            sp: document.metrics.sp,
        ).layoutFont
        let provider = FontMetrics.provider
        let frameWidth = provider.typographicWidth(
            text: text,
            font: font,
        )
        let frameHeight = provider.ascent(font: font)
            + provider.descent(font: font)
        // This is metric arithmetic against the platform text field's own line
        // box, so expect agreement within about a point, not exact pixels.
        // Element-identity-based anchors are the durable fix recorded in
        // the design spec's section 8 follow-ups.
        return CGPoint(
            x: origin.x + frameWidth / 2,
            y: kind == .chordSymbol
                ? origin.y
                : origin.y - frameHeight / 2,
        )
    }

    private var inputField: some View {
        let resolved = EngravedTextFieldFont(
            style: role.textStyle,
            sp: document.metrics.sp,
        )
        return EngravedTextField(
            text: $text,
            font: resolved.platformFont,
            alignment: role.isHorizontallyCentered ? .center : .left,
            focus: focus,
            onSubmit: onSubmit,
            onCancel: onCancel,
        )
        .modifier(EngravedSelectionBlendMode())
        // The preview score is the only source of visible text. The
        // field supplies caret, selection, and IME behavior, while its
        // full editor string (including a marked run) is published to
        // the preview for engraving.
        // Hug the typed text so advancing never covers the syllable
        // immediately to the left. The minimum keeps an empty field
        // visible and clickable without restoring a wide widget box. Text
        // roles omit both additions so their measured origin arithmetic
        // remains honest; their empty caret uses a role-specific fallback.
        .fixedSize(horizontal: true, vertical: false)
        .frame(
            minWidth: role.isHorizontallyCentered
                ? document.metrics.sp * 2.5
                : nil,
        )
        .padding(
            .horizontal,
            role.isHorizontallyCentered ? 2 : 0,
        )
        .focused(focus)
        .onAppear {
            focus.wrappedValue = true
        }
    }
}

private struct EngravedSelectionBlendMode: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
            // The field editor reports a translucent selection colour, but
            // AppKit flattens it before compositing this representable over
            // SwiftUI content. Multiply remains necessary for engraved ink
            // beneath the selection to stay black and readable.
            content.blendMode(.multiply)
        #else
            // UIKit paints its translucent selection beneath the glyph layer,
            // so multiply would darken the engraved text instead of revealing it.
            content
        #endif
    }
}

extension LayoutDocument {
    fileprivate func lyricEntryOrigin(
        at cursor: LyricInputPlanner.Cursor,
    ) -> CGPoint? {
        guard let anchor = chordStemOrigin(at: cursor.location),
              let y = lyricLineY(
                  at: cursor.location,
                  verse: cursor.verse,
              )
        else { return nil }
        return CGPoint(x: anchor.x, y: y)
    }

    fileprivate func textEntryOrigin(
        kind: TextInputPlanner.Kind,
        at anchor: VoiceElementID,
        text: String,
    ) -> CGPoint? {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines,
        )
        let engraved: CGPoint?
        switch kind {
        case .staffText:
            engraved = staffTextOrigin(
                at: anchor, text: trimmed, style: .staffText,
            )
        case .systemText:
            engraved = staffTextOrigin(
                at: anchor, text: trimmed, style: .systemText,
            )
        case .chordSymbol:
            engraved = harmonyOrigin(at: anchor, text: trimmed)
        case .rehearsalMark:
            engraved = rehearsalMarkTextOrigin(at: anchor)
        }
        if let engraved { return engraved }
        guard trimmed.isEmpty else { return nil }
        return emptyTextEntryOrigin(kind: kind, at: anchor)
    }

    private func emptyTextEntryOrigin(
        kind: TextInputPlanner.Kind,
        at anchor: VoiceElementID,
    ) -> CGPoint? {
        guard let timedOrigin = timedElementOrigin(at: anchor) else {
            return nil
        }
        for system in systems {
            guard let measure = system.measures.first(where: {
                $0.measureIndex == anchor.measureIndex
            }),
                let staffIndex = system.flatIndex(for: anchor.staff),
                system.staffOrigins.indices.contains(staffIndex),
                let topStaffOrigin = system.staffOrigins.first
            else { continue }

            let sp = system.sp
            let staffTop = system.origin.y
                + system.staffOrigins[staffIndex].y
            let systemTop = system.origin.y + topStaffOrigin.y
            switch kind {
            case .staffText:
                return CGPoint(
                    x: timedOrigin.x,
                    y: staffTop - sp * 1.5,
                )
            case .systemText:
                return CGPoint(
                    x: timedOrigin.x,
                    y: systemTop - sp * 3,
                )
            case .rehearsalMark:
                // New rehearsal marks are placed half a spatium into
                // the measure with their frame 1.5 sp above the top
                // staff. Return the inset text origin used by the live
                // renderer so neither caret nor box jumps on first input.
                let pad = RehearsalMarkFrame.paddingSp(sp: sp)
                return CGPoint(
                    x: system.origin.x + measure.origin.x
                        + sp * 0.5 + pad,
                    y: systemTop - sp * 1.5 - pad,
                )
            case .chordSymbol:
                let y = min(
                    staffTop - sp * 2.5,
                    (chordStemOrigin(at: anchor)?.y ?? staffTop)
                        - sp * 0.5,
                )
                return CGPoint(x: timedOrigin.x, y: y)
            }
        }
        return nil
    }
}

/// Selects the active session and connects the reusable field to score
/// application callbacks without putting session behavior back into the
/// already-large `ContentViewMac`.
@available(macOS 15.0, *)
struct ScoreTextEntryOverlayHost: View {
    let document: LayoutDocument
    let lyricSession: LyricInputSession
    let textSession: TextInputSession
    let controller: NoteInputController
    let undoManager: UndoManager?
    let focus: FocusState<Bool>.Binding
    let onApplied: (Score, VoiceElementID?) -> Void
    let onError: (Error) -> Void

    var body: some View {
        @Bindable var lyricSession = lyricSession
        @Bindable var textSession = textSession

        if let cursor = lyricSession.cursor,
           let origin = document.lyricEntryOrigin(at: cursor)
        {
            ScoreTextEntryOverlay(
                document: document,
                origin: origin,
                role: .lyric,
                text: $lyricSession.text,
                focus: focus,
                onSubmit: submitLyric,
                onCancel: cancel,
            )
            .id(ScoreTextEntryOverlayIdentity.lyric(cursor))
        } else if let anchor = textSession.anchor,
                  let origin = document.textEntryOrigin(
                      kind: textSession.kind,
                      at: anchor,
                      text: textSession.text,
                  )
        {
            ScoreTextEntryOverlay(
                document: document,
                origin: origin,
                role: .text(textSession.kind),
                text: $textSession.text,
                focus: focus,
                onSubmit: submitText,
                onCancel: cancel,
            )
            .id(ScoreTextEntryOverlayIdentity.text(
                kind: textSession.kind.overlayIdentity,
                anchor: anchor,
            ))
        }
    }

    private func submitLyric() {
        do {
            let affected = try lyricSession.commit(
                .none,
                controller: controller,
                undoManager: undoManager,
            )
            onApplied(controller.score, affected)
        } catch {
            onError(error)
        }
        lyricSession.end()
        focus.wrappedValue = false
    }

    private func submitText() {
        do {
            let affected = try textSession.commit(
                advance: false,
                controller: controller,
                undoManager: undoManager,
            )
            onApplied(controller.score, affected)
            textSession.end()
            focus.wrappedValue = false
        } catch {
            onError(error)
        }
    }

    private func cancel() {
        lyricSession.end()
        textSession.end()
        focus.wrappedValue = false
    }
}
