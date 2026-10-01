import CDirect2D
import Foundation
import SheetMusicBridgeCore
import SheetMusicLayout
import Synchronization

// `Foundation` on Windows ships its own `CGFloat` / `CGRect`, and `SheetMusicLayout` its stand-ins, which are the
// ones `FontMetricsProvider` speaks. Every CG name in this file is spelled `SheetMusicLayout.…` so none resolves to
// Foundation's (`CGTypes+Android.swift` has the details). Its `CGFloat` is `Double`.

/// Installs the layout's font metrics on Windows: the measured table (`sheet-music.smft`, as `installFontMetricsTable`
/// installs it for the portable hosts) for every face it carries, and DirectWrite for the platform UI face, which the
/// renderer draws in Segoe UI. Call it once, before the first layout, in place of `installFontMetricsTable`.
///
/// Throws when the bytes do not decode or DirectWrite cannot resolve Segoe UI; the provider is left as it was.
/// `installWindowsFontMetrics()` passes the table bundled with this module; this is for a host that ships its own.
public func installWindowsFontMetrics(tableBytes: Data) throws {
    let table = try FontMetricsTable.decode(tableBytes)
    FontMetrics.provider = try WindowsFontMetricsProvider(base: makeFontMetricsTableProvider(table: table))
}

/// The table provider, except for the empty face — the platform UI face that notation labels (part labels, measure
/// numbers, staff names, jumps) ask for in semibold — which it measures with DirectWrite.
///
/// A label's x is anchored on its measured ink (right-aligned part labels, `TextInkGeometry.baselineOrigin`), and the
/// renderer cannot move it again, so what is measured has to be what is drawn. The table cannot promise that for Segoe
/// UI (it carries per-scalar advances without kerning, and no Segoe UI at all), so it normalizes the request to Edwin
/// regular; this provider keeps the request and answers it through `cd2d_measure_text`, which lays the text out with
/// the same face and the same `IDWriteTextLayout` as `cd2d_fill_text`.
struct WindowsFontMetricsProvider: FontMetricsProvider {
    /// The family the renderer draws `DrawProgram.FontID.system` in and this provider measures the empty face in.
    static let systemFamily = "Segoe UI"

    private let base: any FontMetricsProvider
    private let measurer: DirectWriteTextMeasurer

    /// Throws when DirectWrite cannot be created or has no Segoe UI: a provider that could not measure the system face
    /// would have to hand it to the table, which then measures a face the renderer does not draw.
    init(base: any FontMetricsProvider) throws {
        self.base = base
        measurer = try DirectWriteTextMeasurer(family: Self.systemFamily)
    }

    /// DirectWrite's weight for a layout weight: bold 700, semibold 600, regular 400 — the walker's order for the
    /// style flags (`DrawCommandWalker.weight`).
    static func directWriteWeight(_ weight: FontWeight) -> Int32 {
        switch weight {
        case .regular: 400
        case .semibold: 600
        case .bold: 700
        }
    }

    /// The system face as asked for, semibold included: this provider measures it and the renderer draws it. Other
    /// faces get the table's normalization.
    func renderingTextFont(_ font: LayoutFont) -> LayoutFont {
        font.face.isEmpty ? font : base.renderingTextFont(font)
    }

    func ascent(font: LayoutFont) -> SheetMusicLayout.CGFloat {
        guard font.face.isEmpty, let face = measurer.measure("", font: font) else { return base.ascent(font: font) }
        return face.ascent
    }

    func descent(font: LayoutFont) -> SheetMusicLayout.CGFloat {
        guard font.face.isEmpty, let face = measurer.measure("", font: font) else { return base.descent(font: font) }
        return face.descent
    }

    func leading(font: LayoutFont) -> SheetMusicLayout.CGFloat {
        guard font.face.isEmpty, let face = measurer.measure("", font: font) else { return base.leading(font: font) }
        return face.lineGap
    }

    /// Glyph boxes are asked for SMuFL codepoints, which the table carries.
    func glyphPathBoundingBox(font: LayoutFont, codepoint: UInt16) -> SheetMusicLayout.CGRect? {
        base.glyphPathBoundingBox(font: font, codepoint: codepoint)
    }

    /// `CTLineGetTypographicBounds`' width on the Mac: the laid-out advance, trailing whitespace included.
    func typographicWidth(text: String, font: LayoutFont) -> SheetMusicLayout.CGFloat {
        guard font.face.isEmpty else { return base.typographicWidth(text: text, font: font) }
        guard !text.isEmpty else { return 0 }
        guard let measured = measurer.measure(text, font: font) else {
            return base.typographicWidth(text: text, font: font)
        }
        return measured.advance
    }

    func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        guard font.face.isEmpty else { return base.inkBounds(text: text, font: font) }
        guard !text.isEmpty else { return InkBounds(leftBearing: 0, width: 0) }
        guard let measured = measurer.measure(text, font: font) else { return base.inkBounds(text: text, font: font) }
        guard let ink = measured.ink else { return InkBounds(leftBearing: 0, width: 0) }
        return InkBounds(leftBearing: ink.minX, width: ink.width)
    }

    /// Each line's outline bounds (Y-up, from its baseline), the lines stacked at ascent + descent + line gap as the
    /// bridge stacks their baselines (`LayoutBridge.emitBaselineText`) — the Apple provider's shape.
    func textInkBounds(text: String, font: LayoutFont) -> SheetMusicLayout.CGRect? {
        guard font.face.isEmpty, let face = measurer.measure("", font: font) else {
            return base.textInkBounds(text: text, font: font)
        }
        let stride = face.ascent + face.descent + face.lineGap
        var result: SheetMusicLayout.CGRect?
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.isEmpty
        {
            guard let ink = measurer.measure(String(line), font: font)?.ink else { continue }
            let box = ink.offsetBy(dx: 0, dy: -Double(index) * stride)
            result = result.map { $0.union(box) } ?? box
        }
        return result
    }
}

/// `cd2d_measure_text` behind a lock and a cache.
///
/// The layout may measure from several threads at once (Swift Testing runs suites in parallel; a host may lay out off
/// its UI thread). The resources' face and format caches, and their single-threaded Direct2D factory, allow one thread
/// at a time, so every call — the cache lookup and, on a miss, the measurement — runs under one `Mutex`. Measurements
/// are kept per (point size, weight, italic, text), as the Apple provider keeps its fonts: a layout asks for the same
/// label, and for the face metrics of the same few sizes, many times over.
final class DirectWriteTextMeasurer: @unchecked Sendable {
    /// One measurement, in points at the requested size.
    struct TextMeasurement: Sendable {
        var ascent: Double
        var descent: Double
        var lineGap: Double
        var advance: Double
        /// The ink rect, Y-up from the baseline origin; nil for no ink.
        var ink: SheetMusicLayout.CGRect?
    }

    private struct Key: Hashable {
        var pointSize: Double
        var weight: Int32
        var italic: Bool
        var text: String
    }

    /// The family, NUL-terminated UTF-16.
    private let family: [UInt16]
    /// Touched only under `cache`'s lock.
    private let resources: OpaquePointer
    private let cache = Mutex<[Key: TextMeasurement]>([:])

    init(family: String) throws {
        var created: OpaquePointer?
        let hresult = cd2d_resources_create(&created)
        guard hresult == 0, let created else {
            throw Direct2DPageRenderer.Failure(
                step: "creating the DirectWrite resources", hresult: hresult == 0 ? -1 : hresult,
            )
        }
        let units = Array(family.utf16) + [0]
        // The face metrics of a regular 12 pt run: fails here, with DirectWrite's reason, when the family is missing.
        // Checked before any stored property is set, so a throw frees the resources here and never in `deinit`.
        var probe = cd2d_text_metrics()
        let probed = units.withUnsafeBufferPointer { units in
            cd2d_measure_text(created, units.baseAddress, 12, 400, 0, nil, 0, &probe)
        }
        guard probed == 0 else {
            cd2d_resources_destroy(created)
            throw Direct2DPageRenderer.Failure(step: "resolving the font \(family)", hresult: probed)
        }
        resources = created
        self.family = units
    }

    deinit {
        cd2d_resources_destroy(resources)
    }

    /// `text` as `cd2d_fill_text` draws it in `font`'s weight and style at `font.pointSize`; nil when DirectWrite
    /// fails. Empty text measures the face alone.
    func measure(_ text: String, font: LayoutFont) -> TextMeasurement? {
        let key = Key(
            pointSize: Double(font.pointSize), weight: WindowsFontMetricsProvider.directWriteWeight(font.weight),
            italic: font.isItalic, text: text,
        )
        return cache.withLock { cache in
            if let cached = cache[key] { return cached }
            guard let measured = measureUncached(key) else { return nil }
            cache[key] = measured
            return measured
        }
    }

    /// Caller holds the lock.
    private func measureUncached(_ key: Key) -> TextMeasurement? {
        var metrics = cd2d_text_metrics()
        let units = Array(key.text.utf16)
        let hresult = family.withUnsafeBufferPointer { family in
            units.withUnsafeBufferPointer { text in
                cd2d_measure_text(
                    resources, family.baseAddress, Float(key.pointSize), key.weight, key.italic ? 1 : 0,
                    text.baseAddress, UInt32(text.count), &metrics,
                )
            }
        }
        guard hresult == 0 else { return nil }
        let ink: SheetMusicLayout.CGRect? = metrics.inkW > 0 && metrics.inkH > 0
            ? SheetMusicLayout.CGRect(
                x: Double(metrics.inkX), y: Double(metrics.inkY),
                width: Double(metrics.inkW), height: Double(metrics.inkH),
            )
            : nil
        return TextMeasurement(
            ascent: Double(metrics.ascent), descent: Double(metrics.descent), lineGap: Double(metrics.lineGap),
            advance: Double(metrics.advance), ink: ink,
        )
    }
}
