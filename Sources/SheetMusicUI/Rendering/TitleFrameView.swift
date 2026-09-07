import QuartzCore
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// SwiftUI host for the CALayer-rendered title block.
/// `ScoreView`'s vertical and horizontal stacks place an instance
/// at the document's top-leading corner so the title block sits
/// above the first system in the same coordinate space the layout
/// engine produced.
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
        _LayerBackedTitleFrame(frame: frame, width: width)
            .frame(width: width, height: frame.height)
    }
}

// MARK: - Layer building

@available(macOS 15.0, *)
enum TitleFrameLayerBuilder {
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
        let height = frame.height
        let root = CALayer()
        root.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: height),
        )
        root.masksToBounds = false
        for line in TitleFrameRenderer.placedLines(frame) {
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
        return root
    }
}

// MARK: - Platform-backed representable

#if os(macOS)
    @available(macOS 15.0, *)
    private struct _LayerBackedTitleFrame: NSViewRepresentable {
        let frame: LayoutTitleFrame
        let width: CGFloat

        func makeNSView(context: Context) -> LayerTitleFrameHostView {
            let view = LayerTitleFrameHostView()
            view.configure(frame: frame, width: width)
            return view
        }

        func updateNSView(
            _ nsView: LayerTitleFrameHostView, context: Context,
        ) {
            nsView.configure(frame: frame, width: width)
        }
    }

    /// See the note on `LayerSystemHostView`: the backing layer is
    /// left in its native Y-up orientation and the LayoutEngine's
    /// Y-down coordinates are flipped exactly once, inside
    /// `ScoreLayerBuilder`, against the height passed to it.
    @available(macOS 15.0, *)
    private final class LayerTitleFrameHostView: NSView {
        private var lastFrame: LayoutTitleFrame?
        private var lastWidth: CGFloat?

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

        func configure(frame: LayoutTitleFrame, width: CGFloat) {
            guard let hostLayer = layer else { return }
            guard lastFrame != frame || lastWidth != width else {
                return
            }
            hostLayer.sublayers?.forEach {
                $0.removeFromSuperlayer()
            }
            hostLayer.addSublayer(
                TitleFrameLayerBuilder.build(
                    frame: frame, width: width,
                ),
            )
            setFrameSize(NSSize(width: width, height: frame.height))
            lastFrame = frame
            lastWidth = width
        }
    }

#else
    @available(macOS 15.0, *)
    private struct _LayerBackedTitleFrame: UIViewRepresentable {
        let frame: LayoutTitleFrame
        let width: CGFloat

        func makeUIView(context: Context) -> LayerTitleFrameHostView {
            let view = LayerTitleFrameHostView()
            view.configure(frame: frame, width: width)
            return view
        }

        func updateUIView(
            _ uiView: LayerTitleFrameHostView, context: Context,
        ) {
            uiView.configure(frame: frame, width: width)
        }
    }

    @available(macOS 15.0, *)
    private final class LayerTitleFrameHostView: UIView {
        private var lastFrame: LayoutTitleFrame?
        private var lastWidth: CGFloat?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .white
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        func configure(frame: LayoutTitleFrame, width: CGFloat) {
            guard lastFrame != frame || lastWidth != width else {
                return
            }
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer.addSublayer(
                TitleFrameLayerBuilder.build(
                    frame: frame, width: width,
                ),
            )
            lastFrame = frame
            lastWidth = width
        }
    }
#endif
