import Foundation

/// Where a subtitle block is anchored on the video canvas.
public enum SubtitleAnchor: String, Codable, Sendable, CaseIterable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case center
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    /// Maps an ASS/SSA `\an` value (1–9) to an anchor.
    public init?(assAlignment: Int) {
        switch assAlignment {
        case 1: self = .bottomLeft
        case 2: self = .bottomCenter
        case 3: self = .bottomRight
        case 4: self = .middleLeft
        case 5: self = .center
        case 6: self = .middleRight
        case 7: self = .topLeft
        case 8: self = .topCenter
        case 9: self = .topRight
        default: return nil
        }
    }
}

/// A normalized text position. `x` and `y` are fractions of the canvas.
public struct SubtitlePosition: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var anchor: SubtitleAnchor

    public init(x: Double, y: Double, anchor: SubtitleAnchor = .bottomCenter) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
        self.anchor = anchor
    }
}

/// A decoded image subtitle bitmap in RGBA order.
public struct SubtitleImage: Sendable, Equatable {
    public var width: Int
    public var height: Int

    /// Premultiplied RGBA bytes, `width * height * 4` long.
    public var pixels: Data

    /// Left edge in video pixels.
    public var x: Int

    /// Top edge in video pixels.
    public var y: Int

    public init(
        width: Int,
        height: Int,
        pixels: Data,
        x: Int = 0,
        y: Int = 0
    ) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = pixels
        self.x = x
        self.y = y
    }
}

/// The body of a subtitle cue.
public enum SubtitleContent: Sendable, Equatable {
    case text(String)
    case image(SubtitleImage)
}

/// One timed subtitle cue.
public struct SubtitleCue: Sendable, Equatable, Identifiable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var content: SubtitleContent
    public var isForced: Bool
    public var alignment: SubtitleAnchor
    public var position: SubtitlePosition?
    public var styleName: String?
    public var isBold: Bool
    public var isItalic: Bool

    public init(
        id: Int,
        start: TimeInterval,
        end: TimeInterval,
        content: SubtitleContent,
        isForced: Bool = false,
        alignment: SubtitleAnchor = .bottomCenter,
        position: SubtitlePosition? = nil,
        styleName: String? = nil,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.content = content
        self.isForced = isForced
        self.alignment = alignment
        self.position = position
        self.styleName = styleName
        self.isBold = isBold
        self.isItalic = isItalic
    }

    /// Text content, when this is a text cue.
    public var text: String? {
        if case .text(let text) = content {
            return text
        }
        return nil
    }

    /// Image content, when this is a bitmap cue.
    public var image: SubtitleImage? {
        if case .image(let image) = content {
            return image
        }
        return nil
    }

    public var isImageBased: Bool {
        image != nil
    }

    public var duration: TimeInterval {
        max(0, end - start)
    }
}

/// An 8-bit RGBA color.
public struct SubtitleColor: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
        self.alpha = min(1, max(0, alpha))
    }

    public static let white = SubtitleColor(red: 1, green: 1, blue: 1)
    public static let black = SubtitleColor(red: 0, green: 0, blue: 0)

    /// Parses `&HAABBGGRR` ASS colors. The alpha byte is inverted: `00` is
    /// opaque and `FF` is transparent.
    public init?(assColor value: String) {
        var hex = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if hex.hasPrefix("&H") {
            hex.removeFirst(2)
        }
        if hex.hasSuffix("&") {
            hex.removeLast()
        }
        guard let raw = UInt32(hex, radix: 16) else {
            return nil
        }
        let alpha = Double(255 - ((raw >> 24) & 0xFF)) / 255
        let blue = Double((raw >> 16) & 0xFF) / 255
        let green = Double((raw >> 8) & 0xFF) / 255
        let red = Double(raw & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// User-adjustable subtitle styling (PB-2, doc 04 §2.3).
public struct SubtitleAppearance: Sendable, Equatable {
    public var fontName: String
    public var fontSize: Double
    public var fontScale: Double
    public var opacity: Double
    public var color: SubtitleColor
    public var outlineColor: SubtitleColor
    public var outlineWidth: Double

    /// Vertical offset in fraction-of-canvas units. Positive moves up.
    public var positionOffset: Double

    public init(
        fontName: String = "Helvetica",
        fontSize: Double = 48,
        fontScale: Double = 1,
        opacity: Double = 1,
        color: SubtitleColor = .white,
        outlineColor: SubtitleColor = .black,
        outlineWidth: Double = 2,
        positionOffset: Double = 0
    ) {
        self.fontName = fontName
        self.fontSize = max(8, fontSize)
        self.fontScale = min(2, max(0.5, fontScale))
        self.opacity = min(1, max(0, opacity))
        self.color = color
        self.outlineColor = outlineColor
        self.outlineWidth = max(0, outlineWidth)
        self.positionOffset = positionOffset
    }

    /// Effective point size for a canvas height, relative to a 1080p baseline.
    public func resolvedFontSize(canvasHeight: Int) -> Double {
        let scale = Double(max(1, canvasHeight)) / 1_080
        return fontSize * fontScale * scale
    }
}

/// A parsed subtitle track.
public struct SubtitleDocument: Sendable, Equatable {
    public var format: SubtitleFormat
    public var cues: [SubtitleCue]
    public var playResX: Int?
    public var playResY: Int?

    public init(
        format: SubtitleFormat,
        cues: [SubtitleCue],
        playResX: Int? = nil,
        playResY: Int? = nil
    ) {
        self.format = format
        self.cues = cues.sorted { $0.start < $1.start }
        self.playResX = playResX
        self.playResY = playResY
    }

    public var isImageBased: Bool {
        cues.contains { $0.isImageBased }
    }
}

/// The cues and style needed to produce one overlay frame.
public struct SubtitleRenderPlan: Sendable, Equatable {
    public var cues: [SubtitleCue]
    public var appearance: SubtitleAppearance
    public var canvasWidth: Int
    public var canvasHeight: Int

    public init(
        cues: [SubtitleCue],
        appearance: SubtitleAppearance,
        canvasWidth: Int,
        canvasHeight: Int
    ) {
        self.cues = cues
        self.appearance = appearance
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }
}

public enum SubtitleParseError: Error, LocalizedError, Equatable {
    case unsupportedFormat(String)
    case malformedCue(line: Int)
    case invalidTimestamp(String, line: Int)
    case invalidImageData(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "No subtitle parser is available for '\(format)'."
        case .malformedCue(let line):
            return "Malformed subtitle cue at line \(line)."
        case .invalidTimestamp(let value, let line):
            return "Invalid subtitle timestamp '\(value)' at line \(line)."
        case .invalidImageData(let message):
            return "Invalid image subtitle data: \(message)"
        }
    }
}

/// A parser for one subtitle format.
public protocol SubtitleParsing: Sendable {
    func parse(_ data: Data) throws -> SubtitleDocument
}
