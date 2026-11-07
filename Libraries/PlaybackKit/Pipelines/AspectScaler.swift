import Foundation

/// 21:9 ultrawide and anamorphic stretch processing (doc 06 §2.4, P2).
///
/// Two sources of square-pixel distortion need undoing before a 2.39:1
/// master reaches a 16:9 display:
///
/// 1. **Anamorphic squeeze** — the container declares a pillarboxed
///    (typically 4:3) shape while the pixels are meant to be stretched
///    horizontally (the classic DVD/MKV "anamorphic" hint).
/// 2. **Custom letterboxing** — a 2.39:1 picture shown inside a container
///    with burned-in black bars that the user wants off-screen, or a 16:9
///    source the viewer prefers framed tight.
///
/// ``AspectScaler`` computes the display transform (crop to output ratio,
/// letterbox, or stretch to declared aspect) using AVFoundation-compatible
/// unit-space rectangles, so the player layer renders the intended viewport
/// regardless of `AVLayerVideoGravity`.
public enum AspectScalerError: Error, Equatable {
    case nonPositiveDimensions(width: Double, height: Double)
}

/// Display aspect-ratio intent for a video source.
public enum AspectDisplayMode: Equatable {
    /// Respect the container as-is (default; pillars/letter stays).
    case contained

    /// De-squeeze an anamorphic container using the declared pixel aspect
    /// ratio (e.g. 864/480 pixels with PAR 2.0 → 2.35:1) and letterbox on
    /// the output.
    case anamorphicDequeeze

    /// Fill a 2.39:1 output frame by cropping the container's letter or
    /// pillar bars off (`21:9` mode on the sink).
    case customLetterbox

    /// Force the frame to the given width/height ratio, stretching the
    /// pixels if needed — the user-chosen mode behind the "anamorphic"
    /// hint toggle.
    case stretch(to: Double)

    /// Technical target ratio the mode implies, in width / height units.
    public var targetRatio: Double? {
        switch self {
        case .contained:
            return nil
        case .anamorphicDequeeze:
            return nil
        case .customLetterbox:
            return 2.388888888888889 // 2.39:1, the DCI scope ratio
        case .stretch(let ratio):
            return ratio
        }
    }
}

/// The display-space transform a player applies to one source frame.
///
/// All rectangles use AVFoundation unit space (0…1), so the numbers can go
/// straight into `contentsRect`/`AVSampleBufferDisplayLayer` geometry.
public struct AspectDisplayTransform: Equatable {
    /// Source rectangle to show, in unit space.
    public var sourceRect: AspectRect

    /// Aspect ratio of ``sourceRect`` after any view transform; the player
    /// letterboxes this into the screen.
    public var displayAspectRatio: Double

    /// Removal flags the badge/report should surface to the user.
    public var removedBlackBars: Bool

    public init(
        sourceRect: AspectRect,
        displayAspectRatio: Double,
        removedBlackBars: Bool
    ) {
        self.sourceRect = sourceRect
        self.displayAspectRatio = displayAspectRatio
        self.removedBlackBars = removedBlackBars
    }
}

/// A unit-space rectangle used by ``AspectDisplayTransform``.
public struct AspectRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = AspectRect(x: 0, y: 0, width: 1, height: 1)
}

/// Computes the aspect transforms for ultrawide/anamorphic playback.
public enum AspectScaler {
    /// The ratio threshold at which a frame is considered to carry scope
    /// content (21:9 letterboxing is detected per-frame by black-bar
    /// analysis in the sink layer).
    public static let scopeRatio = 2.388888888888889

    /// Standard 21:9 marketing ratio (2560:1080).
    public static let ultrawideRatio = 256.0 / 108.0

    /// Calculates the transform for one source on one screen.
    ///
    /// - Parameters:
    ///   - pixelWidth/pixelHeight: encoded frame dimensions.
    ///   - pixelAspect: width/height of a single pixel (1 is square).
    ///   - mode: what the user (or the sink profile) asked for.
    public static func transform(
        pixelWidth: Double,
        pixelHeight: Double,
        pixelAspect: Double = 1,
        mode: AspectDisplayMode
    ) throws -> AspectDisplayTransform {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw AspectScalerError.nonPositiveDimensions(
                width: pixelWidth,
                height: pixelHeight
            )
        }

        switch mode {
        case .contained:
            let contentRatio = (pixelWidth * pixelAspect) / pixelHeight
            return AspectDisplayTransform(
                sourceRect: .full,
                displayAspectRatio: contentRatio,
                removedBlackBars: false
            )

        case .anamorphicDequeeze:
            let squeezed = pixelWidth / pixelHeight
            let contentRatio = squeezed * pixelAspect
            let barsRemoved = pixelHeight > 0 && squeezed < contentRatio
            // The container shows the squeezed frame; de-squeezing keeps
            // the full picture but re-letterboxes it by content ratio.
            return AspectDisplayTransform(
                sourceRect: .full,
                displayAspectRatio: contentRatio,
                removedBlackBars: barsRemoved
            )

        case .customLetterbox:
            return try showWidescreenWindow(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                pixelAspect: pixelAspect,
                targetRatio: mode.targetRatio!
            )

        case .stretch(let ratio):
            return AspectDisplayTransform(
                sourceRect: .full,
                displayAspectRatio: ratio,
                removedBlackBars: false
            )
        }
    }

    /// Crops the container down to the scope window: the widest strip that
    /// preserves the target ratio inside the picture, sliced from the
    /// vertical center (a 2.39:1 strip inside 16:9 removes the letter bars
    /// top and bottom).
    static func showWidescreenWindow(
        pixelWidth: Double,
        pixelHeight: Double,
        pixelAspect: Double,
        targetRatio: Double
    ) throws -> AspectDisplayTransform {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw AspectScalerError.nonPositiveDimensions(
                width: pixelWidth,
                height: pixelHeight
            )
        }
        let squareWidth = pixelWidth * pixelAspect
        var contentRatio = squareWidth / pixelHeight

        var crop = AspectRect.full
        var barsRemoved = false

        if contentRatio < targetRatio {
            // Picture is *narrower* than the target (e.g. 16:9 container
            // with scope content inside): crop vertically around the
            // middle so the removed strip is the (letter) bars.
            let scale = contentRatio / targetRatio
            crop.y = (1.0 - scale) / 2.0
            crop.height = scale
            barsRemoved = true
            contentRatio = targetRatio
        } else if contentRatio > targetRatio {
            // Picture is wider than the target (pillar-ish sides): crop
            // horizontally around the middle.
            let scale = targetRatio / contentRatio
            crop.x = (1.0 - scale) / 2.0
            crop.width = scale
            barsRemoved = true
            contentRatio = targetRatio
        }

        return AspectDisplayTransform(
            sourceRect: crop,
            displayAspectRatio: contentRatio,
            removedBlackBars: barsRemoved
        )
    }

    /// Renderer-independent helper: the video rect (in screen unit space)
    /// a given container's aspect occupies, honoring the sink display
    /// mode. Used by the player view model for
    /// `AVLayerVideoGravity.resizeAspectFill` planning.
    public static func videoFrame(
        contentAspectRatio content: Double,
        screenRatio: Double
    ) -> AspectRect {
        if content >= screenRatio {
            let height = screenRatio / content
            return AspectRect(
                x: 0,
                y: (1.0 - height) / 2.0,
                width: 1,
                height: height
            )
        } else {
            let width = content / screenRatio
            return AspectRect(
                x: (1.0 - width) / 2.0,
                y: 0,
                width: width,
                height: 1
            )
        }
    }

    /// Whether a sink aspect choice can be presented as "ultrawide"
    /// (21:9 > everything between 2.20 and 2.42 is scope-class).
    public static func isUltrawide(_ ratio: Double) -> Bool {
        ratio >= 2.20 && ratio <= 2.45
    }
}
