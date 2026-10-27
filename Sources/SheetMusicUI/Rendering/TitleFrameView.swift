import QuartzCore
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// SwiftUI host for the CALayer-rendered title block, without
/// pictures: `FrameContentView` with no images, at the block's own
/// height. `ScoreView` itself draws the title through
/// `FrameContentView`, so that the block's pictures come with it.
///
/// **A layer tree, for the same reason `SystemLayerView` is one.**
/// This used to be a SwiftUI `Canvas`, which rasterises once at its
/// layout size — so magnifying the page magnified that bitmap and
/// the title went soft while the engraving under it stayed crisp.
/// The systems left the `Canvas` behind when they became layer
/// trees; the title block was the one part of the page still drawn
/// the old way. Glyph outlines in a `CAShapeLayer` are re-rendered
/// at whatever scale the host ends up at, so the title tracks the
/// zoom like everything else on the paper.
///
/// The PDF exporter keeps drawing through `TitleFrameRenderer`: a
/// `GraphicsContext` writing into a PDF is resolution-independent
/// already, so it has nothing to gain here. Both sides take their
/// per-line placement from `TitleFrameRenderer.placedLines`, which
/// is what stops the screen and the export from drifting apart.
@available(macOS 15.0, *)
struct TitleFrameView: View {
    let frame: LayoutTitleFrame
    let width: CGFloat

    var body: some View {
        FrameContentView(frame: frame, images: [], width: width, height: frame.height)
    }
}

/// One box's layer-rendered content, its texts and its pictures, `width` × `height` points: the title block with
/// `LayoutDocument.titleImages`, or a frame between systems with its own `images`. `ScoreView` places it at the box's
/// top. Picture rects are in the box's own space, y down from its top.
@available(macOS 15.0, *)
struct FrameContentView: View {
    let frame: LayoutTitleFrame
    let images: [LayoutFrameImage]
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        _LayerBackedTitleFrame(
            content: FrameLayerContent(frame: frame, images: images, width: width, height: height),
        )
        .frame(width: width, height: height)
    }
}

/// What one box's layer tree is built from. The host views rebuild the tree only when it changes.
@available(macOS 15.0, *)
private struct FrameLayerContent: Equatable {
    let frame: LayoutTitleFrame
    let images: [LayoutFrameImage]
    let width: CGFloat
    let height: CGFloat

    func build() -> CALayer {
        TitleFrameLayerBuilder.build(frame: frame, images: images, width: width, height: height)
    }
}

// MARK: - Layer building

/// The layer tree of a box's content — the title block or a frame between systems — as `ScoreView` hosts it. Public
/// for a host that draws a box itself, outside a view (a video frame of the page's top).
@available(macOS 15.0, *)
public enum TitleFrameLayerBuilder {
    /// The block's own layer: a white page under the title texts.
    ///
    /// White, because the staff drawing assumes white paper and the
    /// title block sits on the same sheet. It is painted by the
    /// host view's backing layer rather than a filled sublayer, so
    /// there is no second rect to disagree with the laid-out size —
    /// the black hairline down the trailing edge that the `Canvas`
    /// version had to fill against cannot come back.
    static func build(
        frame: LayoutTitleFrame, width: CGFloat,
    ) -> CALayer {
        build(frame: frame, images: [], width: width, height: frame.height)
    }

    /// `build(frame:width:)` for a block `height` points tall that also holds `images`: the title block with
    /// `LayoutDocument.titleImages`, or a frame between systems with its own. The texts are flipped about `height`,
    /// and each picture becomes one image layer after them (`FrameImageDrawing.layers`), in the order the draw program
    /// draws a box. Picture rects are in the block's own space, y down from its top. The root is `width` × `height`
    /// with no background: the host paints the paper.
    ///
    /// Builds the whole tree at the call: every text outline is resolved then, in the face the `FontMetrics.provider`
    /// current at the call draws it in (`RenderingTextFace` — Edwin inside a `FontMetrics.withProvider` scope over the
    /// portable table), and the layers hold paths, not fonts. So a host whose layout was measured inside a scope calls
    /// this inside the same kind of scope, and the tree keeps that face after the scope ends. `ScoreView` builds its
    /// boxes in its own view updates, outside any caller's scope.
    public static func build(
        frame: LayoutTitleFrame, images: [LayoutFrameImage], width: CGFloat, height: CGFloat,
    ) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: height),
        )
        root.masksToBounds = false
        for line in TitleFrameRenderer.placedLines(frame) {
            if !line.richRuns.isEmpty {
                if let path = ScoreLayerBuilder.richTextPath(runs: line.richRuns, decorations: line.richDecorations) {
                    root.addSublayer(ScoreLayerBuilder.fillLayer(path: path, height: height))
                }
                continue
            }
            guard let layer = ScoreLayerBuilder.textLayer(
                text: line.text,
                at: line.position,
                size: line.fontSize,
                italic: false,
                // The placed anchor is always a TOP one, so only the
                // horizontal component varies; `y: 0` is the top of
                // the line box, which is what `Canvas`'s
                // `.topLeading` / `.top` / `.topTrailing` meant.
                anchor: CGPoint(x: line.anchor.x, y: 0),
                color: ScoreLayerBuilder.inkColor,
                font: TitleFrameRenderer.ctFont(size: line.fontSize),
                height: height,
            ) else { continue }
            root.addSublayer(layer)
        }
        for layer in FrameImageDrawing.layers(for: images, height: height) {
            root.addSublayer(layer)
        }
        return root
    }
}

// MARK: - Platform-backed representable

#if os(macOS)
    @available(macOS 15.0, *)
    private struct _LayerBackedTitleFrame: NSViewRepresentable {
        let content: FrameLayerContent

        func makeNSView(context: Context) -> LayerTitleFrameHostView {
            let view = LayerTitleFrameHostView()
            view.configure(content)
            return view
        }

        func updateNSView(
            _ nsView: LayerTitleFrameHostView, context: Context,
        ) {
            nsView.configure(content)
        }
    }

    /// See the note on `LayerSystemHostView`: the backing layer is
    /// left in its native Y-up orientation and the LayoutEngine's
    /// Y-down coordinates are flipped exactly once, inside
    /// `ScoreLayerBuilder`, against the height passed to it.
    @available(macOS 15.0, *)
    private final class LayerTitleFrameHostView: NSView {
        private var lastContent: FrameLayerContent?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = CGColor(gray: 1, alpha: 1)
            layer?.masksToBounds = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        func configure(_ content: FrameLayerContent) {
            guard let hostLayer = layer else { return }
            guard lastContent != content else { return }
            hostLayer.sublayers?.forEach {
                $0.removeFromSuperlayer()
            }
            hostLayer.addSublayer(content.build())
            setFrameSize(NSSize(width: content.width, height: content.height))
            lastContent = content
        }
    }

#else
    @available(macOS 15.0, *)
    private struct _LayerBackedTitleFrame: UIViewRepresentable {
        let content: FrameLayerContent

        func makeUIView(context: Context) -> LayerTitleFrameHostView {
            let view = LayerTitleFrameHostView()
            view.configure(content)
            return view
        }

        func updateUIView(
            _ uiView: LayerTitleFrameHostView, context: Context,
        ) {
            uiView.configure(content)
        }
    }

    @available(macOS 15.0, *)
    private final class LayerTitleFrameHostView: UIView {
        private var lastContent: FrameLayerContent?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .white
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        func configure(_ content: FrameLayerContent) {
            guard lastContent != content else { return }
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer.addSublayer(content.build())
            lastContent = content
        }
    }
#endif
