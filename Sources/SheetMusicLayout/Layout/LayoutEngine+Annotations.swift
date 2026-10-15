#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// How an annotation's text hangs off the x it is placed at.
    enum AnnotationAlignment {
        /// Left edge at x (MuseScore's `AlignH::LEFT`: expression, capo, staff text).
        case leading
        /// Centered on x (`AlignH::HCENTER`: sticking, fingering).
        case center
    }

    /// What one annotation draws: its text and the style / role MuseScore draws it with.
    struct AnnotationTextSpec {
        let text: String
        let richText: RichText?
        let style: TextStyleType
        let role: TextPlacementRole
        let properties: ElementProperties
        let overrides: TextProperties
        let alignment: AnnotationAlignment
        /// MuseScore moves a `StringTunings` to one spatium right of its measure's left edge instead of its segment
        /// (`TLayout::layoutStringTunings`, `tlayout.cpp:5367`).
        let anchorsAtMeasureStart: Bool
        /// The style's position row is the text's vertical CENTER (`AlignV::VCENTER`: the harp pedal diagram), not
        /// its first baseline.
        var verticalCenter = false
    }

    /// The text spec of a voice-level annotation, or `nil` for any other element or an empty text.
    static func annotationSpec(for element: VoiceElement) -> AnnotationTextSpec? {
        guard let spec = annotationSpecIgnoringEmptiness(for: element),
              !spec.text.isEmpty || spec.richText != nil
        else { return nil }
        return spec
    }

    private static func annotationSpecIgnoringEmptiness(for element: VoiceElement) -> AnnotationTextSpec? {
        switch element {
        case let .expression(expression):
            AnnotationTextSpec(
                text: expression.text, richText: expression.richText, style: .expression, role: .expression,
                properties: expression.elementProperties, overrides: expression.fontOverrides,
                alignment: .leading, anchorsAtMeasureStart: false,
            )
        case let .sticking(sticking):
            AnnotationTextSpec(
                text: sticking.text, richText: sticking.richText, style: .sticking, role: .sticking,
                properties: sticking.elementProperties, overrides: sticking.fontOverrides,
                alignment: .center, anchorsAtMeasureStart: false,
            )
        case let .capo(capo):
            // The instrument's string count is not known here, so a partial capo with an empty text draws nothing.
            AnnotationTextSpec(
                text: capo.displayedText(stringCount: nil), richText: capo.richText, style: .staffText,
                role: .staffText, properties: capo.elementProperties, overrides: capo.fontOverrides,
                alignment: .leading, anchorsAtMeasureStart: false,
            )
        case let .stringTunings(tunings):
            AnnotationTextSpec(
                text: tunings.text, richText: tunings.richText, style: .stringTunings, role: .staffText,
                properties: tunings.elementProperties, overrides: tunings.fontOverrides,
                alignment: .leading, anchorsAtMeasureStart: true,
            )
        default:
            nil
        }
    }

    /// The `.staffText` element MuseScore's `TextBase` layout gives `spec` at `x`: the first baseline on the style's
    /// position row of the placement side (`placedTextOrigin`), centered or left-aligned on `x`, carrying its style,
    /// placement metadata (so the skyline pass lifts it on its side unless `<autoplace>0`) and font overrides. No
    /// `anchor` and no `identity`: no text-entry command addresses an annotation (`LayoutElement.staffText`'s doc).
    static func annotationStaffText(
        _ spec: AnnotationTextSpec, x: CGFloat,
        textPlacementStyle: TextPlacementStyles, lineGeometry: StaffLineGeometry, metrics: StaffMetrics,
    ) -> LayoutElement {
        let rich = spec.richText.map {
            LayoutRichText($0, style: spec.style, overrides: spec.overrides, metrics: metrics)
        }
        let font = TextInkGeometry.font(for: spec.style, overrides: spec.overrides, metrics: metrics)
        let width = rich?.size.width ?? TextInkGeometry.typographicSize(text: spec.text, font: font).width
        let left = spec.alignment == .center ? x - width / 2 : x
        let side = textPlacementStyle.side(for: spec.role, element: spec.properties)
        // `center: true` would be the origin of a CENTER-anchored element (a lyric); every `.staffText` hangs from its
        // bottom edge (`TextInkGeometry.rects`: anchor (0, 1)). So a vertically centered style row is seated here
        // instead: the first baseline lies half (ascent − descent) below the row.
        var origin = placedTextOrigin(
            text: spec.text, role: spec.role, properties: spec.properties, style: textPlacementStyle,
            x: left, lineGeometry: lineGeometry, metrics: metrics, font: font, center: false, rich: rich,
        )
        if spec.verticalCenter {
            let provider = FontMetrics.provider
            let ascent = rich?.lines.first?.ascent ?? provider.ascent(font: font)
            let descent = rich?.lines.first?.descent ?? provider.descent(font: font)
            origin.y += (ascent - descent) / 2
        }
        return .staffText(
            text: spec.text, origin: origin, color: spec.properties.color, style: spec.style, anchor: nil,
            placement: TextPlacementMetadata(side: side, autoplace: spec.properties.autoplace ?? true),
            properties: spec.overrides.fontOverrides, identity: nil, richText: rich,
        )
    }
}
