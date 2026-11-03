import CoreGraphics
import CoreText
import Foundation
import Metal

public enum SubtitleRendererError: Error, LocalizedError, Equatable {
    case deviceUnavailable
    case contextCreationFailed
    case textureCreationFailed
    case invalidImage
    case commandEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "No Metal device is available for subtitle rendering."
        case .contextCreationFailed:
            return "Could not create the subtitle drawing context."
        case .textureCreationFailed:
            return "Could not create the subtitle overlay texture."
        case .invalidImage:
            return "The subtitle image data is not valid RGBA."
        case .commandEncodingFailed:
            return "Could not encode the subtitle overlay command."
        }
    }
}

/// Renders text and PGS bitmap cues into a transparent Metal texture that is
/// composited above the video layer (PB-2, doc 04 §2.3).
public final class MetalSubtitleRenderer: @unchecked Sendable {
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else {
            throw SubtitleRendererError.deviceUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw SubtitleRendererError.commandEncodingFailed
        }
        self.device = device
        self.commandQueue = queue
    }

    /// Rasterizes the plan and uploads it to a shader-readable RGBA texture.
    public func render(_ plan: SubtitleRenderPlan) throws -> MTLTexture {
        let width = max(1, plan.canvasWidth)
        let height = max(1, plan.canvasHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw SubtitleRendererError.contextCreationFailed
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        for cue in plan.cues {
            switch cue.content {
            case .image(let image):
                try draw(
                    image,
                    in: context,
                    canvasWidth: width,
                    canvasHeight: height
                )
            case .text(let text):
                draw(
                    text,
                    cue: cue,
                    appearance: plan.appearance,
                    in: context,
                    canvasWidth: width,
                    canvasHeight: height
                )
            }
        }

        guard let data = context.data else {
            throw SubtitleRendererError.contextCreationFailed
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw SubtitleRendererError.textureCreationFailed
        }
        texture.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: context.bytesPerRow
        )
        return texture
    }

    // MARK: - Image cues

    private func draw(
        _ image: SubtitleImage,
        in context: CGContext,
        canvasWidth: Int,
        canvasHeight: Int
    ) throws {
        guard image.width > 0, image.height > 0,
              image.pixels.count >= image.width * image.height * 4 else {
            throw SubtitleRendererError.invalidImage
        }
        guard let provider = CGDataProvider(data: image.pixels as CFData),
              let cgImage = CGImage(
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw SubtitleRendererError.invalidImage
        }

        let x = CGFloat(image.x)
        let y = CGFloat(canvasHeight - image.y - image.height)
        context.draw(
            cgImage,
            in: CGRect(
                x: x,
                y: y,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
    }

    // MARK: - Text cues

    private func draw(
        _ text: String,
        cue: SubtitleCue,
        appearance: SubtitleAppearance,
        in context: CGContext,
        canvasWidth: Int,
        canvasHeight: Int
    ) {
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else {
            return
        }
        let fontSize = appearance.resolvedFontSize(canvasHeight: canvasHeight)
        let font = CTFontCreateWithName(
            appearance.fontName as CFString,
            CGFloat(fontSize),
            nil
        )
        let color = appearance.color
        let opacity = appearance.opacity
        let textColor = CGColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha * opacity)
        )
        let outlineColor = CGColor(
            red: CGFloat(appearance.outlineColor.red),
            green: CGFloat(appearance.outlineColor.green),
            blue: CGFloat(appearance.outlineColor.blue),
            alpha: CGFloat(appearance.outlineColor.alpha * opacity)
        )

        let lineHeight = CGFloat(fontSize * 1.2)
        let totalHeight = lineHeight * CGFloat(lines.count)
        let anchor = cue.alignment
        let anchorX = cue.position.map {
            CGFloat($0.x) * CGFloat(canvasWidth)
        } ?? CGFloat(canvasWidth) / 2
        let anchorY: CGFloat
        if let position = cue.position {
            anchorY = CGFloat(position.y) * CGFloat(canvasHeight)
                - CGFloat(appearance.positionOffset) * CGFloat(canvasHeight)
        } else {
            anchorY = CGFloat(canvasHeight)
                * (0.92 - CGFloat(appearance.positionOffset))
        }

        let top: CGFloat
        switch anchor {
        case .topLeft, .topCenter, .topRight:
            top = anchorY
        case .middleLeft, .center, .middleRight:
            top = anchorY - totalHeight / 2
        default:
            top = anchorY - totalHeight
        }

        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    textColor
            ]
            let attributed = NSAttributedString(
                string: line,
                attributes: attributes
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let lineWidth = CGFloat(
                CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            )
            let x: CGFloat
            switch anchor {
            case .topLeft, .middleLeft, .bottomLeft:
                x = anchorX
            case .topRight, .middleRight, .bottomRight:
                x = anchorX - lineWidth
            default:
                x = anchorX - lineWidth / 2
            }
            let ascent = CTFontGetAscent(font)
            let baselineY = CGFloat(canvasHeight)
                - (top + CGFloat(index) * lineHeight + ascent)

            context.saveGState()
            context.textPosition = CGPoint(x: x, y: baselineY)
            if appearance.outlineWidth > 0 {
                context.setStrokeColor(outlineColor)
                context.setLineWidth(CGFloat(appearance.outlineWidth))
                context.setTextDrawingMode(.stroke)
                CTLineDraw(ctLine, context)
            }
            context.setFillColor(textColor)
            context.setTextDrawingMode(.fill)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }
}
