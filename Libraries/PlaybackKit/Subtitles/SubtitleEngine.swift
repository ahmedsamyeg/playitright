import Foundation

/// Subtitle demuxing, timing, filtering, and styling for the playback engine
/// (PB-1, PB-2, doc 04 §2.3).
///
/// The engine selects the parser for a track format, filters cues by the
/// forced-only setting, keeps a one-frame timing tolerance, and produces a
/// ``SubtitleRenderPlan`` for the Metal overlay renderer.
public struct SubtitleEngine: Sendable {
    public var document: SubtitleDocument
    public var appearance: SubtitleAppearance
    public var isForcedOnly: Bool

    /// Timing tolerance used when matching a cue to a presentation time.
    /// Defaults to one frame at 24 fps.
    public var frameDuration: TimeInterval

    public init(
        document: SubtitleDocument,
        appearance: SubtitleAppearance = SubtitleAppearance(),
        isForcedOnly: Bool = false,
        frameDuration: TimeInterval = 1.0 / 24.0
    ) {
        self.document = document
        self.appearance = appearance
        self.isForcedOnly = isForcedOnly
        self.frameDuration = max(0, frameDuration)
    }

    /// Parses a subtitle track.
    public init(
        data: Data,
        format: SubtitleFormat,
        appearance: SubtitleAppearance = SubtitleAppearance(),
        isForcedOnly: Bool = false,
        frameDuration: TimeInterval = 1.0 / 24.0
    ) throws {
        self.init(
            document: try Self.parse(data, format: format),
            appearance: appearance,
            isForcedOnly: isForcedOnly,
            frameDuration: frameDuration
        )
    }

    /// Parses subtitle data using the parser for `format`.
    public static func parse(
        _ data: Data,
        format: SubtitleFormat
    ) throws -> SubtitleDocument {
        let parser: any SubtitleParsing
        switch format {
        case .srt:
            parser = SRTParser()
        case .webvtt:
            parser = WebVTTParser()
        case .ass, .ssa:
            parser = ASSParser()
        case .pgs:
            parser = PGSParser()
        default:
            throw SubtitleParseError.unsupportedFormat(format.rawValue)
        }
        var document = try parser.parse(data)
        if format == .ssa {
            document.format = .ssa
        }
        return document
    }

    /// Cues at a presentation time, honoring the forced-only filter.
    public func cues(at time: TimeInterval) -> [SubtitleCue] {
        let tolerance = frameDuration
        return document.cues.filter { cue in
            guard cue.start <= time + tolerance,
                  cue.end >= time - tolerance else {
                return false
            }
            return !isForcedOnly || cue.isForced
        }
    }

    /// Forced cues available in the document.
    public var forcedCues: [SubtitleCue] {
        document.cues.filter(\.isForced)
    }

    /// Toggles forced-only filtering and returns the new state.
    @discardableResult
    public mutating func setForcedOnly(_ enabled: Bool) -> Bool {
        isForcedOnly = enabled
        return isForcedOnly
    }

    /// Adjusts the font scale in 10% steps, clamped to 0.5–2.0.
    @discardableResult
    public mutating func adjustFontSize(by steps: Int) -> Double {
        appearance.fontScale = min(
            2,
            max(0.5, appearance.fontScale + Double(steps) * 0.1)
        )
        return appearance.fontScale
    }

    /// Adjusts the vertical position offset, clamped to ±0.5.
    @discardableResult
    public mutating func adjustPosition(by delta: Double) -> Double {
        appearance.positionOffset = min(
            0.5,
            max(-0.5, appearance.positionOffset + delta)
        )
        return appearance.positionOffset
    }

    /// Sets text opacity, clamped to 0–1.
    @discardableResult
    public mutating func setOpacity(_ opacity: Double) -> Double {
        appearance.opacity = min(1, max(0, opacity))
        return appearance.opacity
    }

    /// Builds the overlay plan for a presentation time.
    public func renderPlan(
        at time: TimeInterval,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> SubtitleRenderPlan {
        SubtitleRenderPlan(
            cues: cues(at: time),
            appearance: appearance,
            canvasWidth: max(1, canvasWidth),
            canvasHeight: max(1, canvasHeight)
        )
    }

    /// Whether any cue in the document is image based.
    public var isImageBased: Bool {
        document.isImageBased
    }
}
