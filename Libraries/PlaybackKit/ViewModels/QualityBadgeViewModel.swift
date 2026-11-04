import CoreKit
import Foundation

/// One labelled row in the pipeline drill-down sheet.
public struct PipelineDetailRow: Identifiable, Sendable, Equatable {
    public var id: String { title }

    public var title: String
    public var value: String

    /// Optional plain-language explanation shown beneath the value.
    public var explanation: String?

    public init(
        title: String,
        value: String,
        explanation: String? = nil
    ) {
        self.title = title
        self.value = value
        self.explanation = explanation
    }
}

/// A group of related rows in the pipeline drill-down sheet.
public struct PipelineDetailSection: Identifiable, Sendable, Equatable {
    public var id: String { title }

    public var title: String
    public var rows: [PipelineDetailRow]

    public init(title: String, rows: [PipelineDetailRow]) {
        self.title = title
        self.rows = rows
    }
}

/// Drives the honest quality badge and the expandable pipeline detail sheet
/// (PRD-D1, PB-5, UI-3, doc 01 §2, doc 06 §2.4).
///
/// The badge is always derived from the plan that was actually chosen, never
/// from what the user hoped for. The view model pairs a plain-language summary
/// with a technical drill-down covering input/output codecs, the color
/// transform, the audio path, the planner's reasons, and thermal state.
public struct QualityBadgeViewModel: Sendable, Equatable {
    public let plan: PipelinePlan
    public var thermalState: ThermalState
    public var preferences: PlaybackPreferences

    public init(
        plan: PipelinePlan,
        thermalState: ThermalState = .nominal,
        preferences: PlaybackPreferences? = nil
    ) {
        self.plan = plan
        self.thermalState = thermalState
        self.preferences = preferences ?? PlaybackPreferences(
            qualityBias: plan.qualityBias,
            colorMode: plan.colorMode
        )
    }

    // MARK: - Badge

    public var badge: QualityBadge {
        plan.badge
    }

    public var label: String {
        plan.badge.label
    }

    public var color: BadgeColor {
        plan.badge.color
    }

    public var rung: PipelineRung {
        plan.rung
    }

    /// A one-sentence, plain-language description of what is happening.
    public var summary: String {
        guard plan.isPlayable else {
            return "This file cannot be played on this Apple TV."
        }

        switch plan.rung {
        case .r1Direct:
            return "Direct play — no conversion."
        case .r2Remux:
            return "Remuxed to MP4 — picture untouched."
        case .r3HardwareTranscode:
            return "Transcoded on this Apple TV using hardware."
        case .r4SoftwareTranscode:
            return "Transcoded on this Apple TV in software."
        case .r5ServerTranscode:
            return "Transcoded by your server."
        }
    }

    /// A compact technical headline for the badge area.
    public var technicalSummary: String {
        let input = "\(Self.codecName(plan.video.inputCodec)) \(resolutionName)"
        let output = "\(Self.codecName(plan.video.outputCodec)) \(Self.hdrName(plan.video.outputHDR))"
        return "\(input) \(Self.hdrName(plan.video.inputHDR)) → \(output)"
    }

    // MARK: - Drill-down

    public var sections: [PipelineDetailSection] {
        var sections: [PipelineDetailSection] = [videoSection, colorSection]
        if let audio = plan.audio {
            sections.append(audioSection(audio))
        }
        sections.append(deviceSection)
        return sections
    }

    /// The planner's ordered explanations, suitable for the sheet's "Why" list.
    public var reasons: [String] {
        plan.reasons
    }

    public var videoSection: PipelineDetailSection {
        var rows: [PipelineDetailRow] = [
            PipelineDetailRow(
                title: "Path",
                value: plan.rung.displayName,
                explanation: summary
            ),
            PipelineDetailRow(
                title: "Input",
                value: "\(Self.codecName(plan.video.inputCodec)) · \(plan.video.inputContainer.rawValue.uppercased())",
                explanation: "\(resolutionName) · \(plan.video.bitDepth)-bit · \(Self.hdrName(plan.video.inputHDR))"
            ),
            PipelineDetailRow(
                title: "Output",
                value: "\(Self.codecName(plan.video.outputCodec)) · \(plan.video.outputContainer.rawValue.uppercased())"
            ),
            PipelineDetailRow(
                title: "Decode",
                value: decodeDescription,
                explanation: decodeExplanation
            )
        ]

        if plan.rungCapApplied {
            rows.append(
                PipelineDetailRow(
                    title: "Quality lock",
                    value: "Capped at \(plan.rung.displayName)",
                    explanation: "A saved path lock stopped the planner from choosing a higher-quality rung."
                )
            )
        }

        return PipelineDetailSection(title: "Video", rows: rows)
    }

    public var colorSection: PipelineDetailSection {
        var rows: [PipelineDetailRow] = [
            PipelineDetailRow(
                title: "Transform",
                value: plan.video.colorTransform.displayName,
                explanation: colorExplanation
            ),
            PipelineDetailRow(
                title: "HDR",
                value: "\(Self.hdrName(plan.video.inputHDR)) → \(Self.hdrName(plan.video.outputHDR))"
            )
        ]

        if usesToneMapping {
            rows.append(
                PipelineDetailRow(
                    title: "Tone-map target",
                    value: "\(Int(preferences.targetPeakNits)) nits"
                )
            )
        }

        return PipelineDetailSection(title: "Color", rows: rows)
    }

    private func audioSection(_ audio: AudioPipelinePlan) -> PipelineDetailSection {
        var rows: [PipelineDetailRow] = [
            PipelineDetailRow(
                title: "Input",
                value: "\(Self.codecName(audio.inputCodec)) · \(audio.channels)ch",
                explanation: audio.language.map { "Language: \($0.uppercased())" }
            ),
            PipelineDetailRow(
                title: "Route",
                value: Self.routeName(audio.route),
                explanation: audio.routeExplanation
            ),
            PipelineDetailRow(
                title: "Output",
                value: "\(Self.codecName(audio.outputCodec)) · \(audio.outputChannels)ch"
            )
        ]

        if audio.isAtmos {
            rows.append(
                PipelineDetailRow(
                    title: "Atmos",
                    value: "Dolby Atmos metadata carried"
                )
            )
        }

        return PipelineDetailSection(title: "Audio", rows: rows)
    }

    public var deviceSection: PipelineDetailSection {
        PipelineDetailSection(
            title: "Device",
            rows: [
                PipelineDetailRow(
                    title: "Thermal",
                    value: thermalStateName,
                    explanation: thermalExplanation
                ),
                PipelineDetailRow(
                    title: "Quality bias",
                    value: Self.biasName(preferences.qualityBias)
                ),
                PipelineDetailRow(
                    title: "Path lock",
                    value: isPathLocked
                        ? "Locked to \(plan.rung.displayName)"
                        : "Automatic"
                )
            ]
        )
    }

    // MARK: - Thermal

    public var thermalStateName: String {
        switch thermalState {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        }
    }

    public var thermalExplanation: String {
        switch thermalState {
        case .nominal:
            return "The Apple TV is running cool."
        case .fair:
            return "The Apple TV is slightly warm; playback is unaffected."
        case .serious:
            return "The Apple TV is warm; software transcoding will drop to 1080p."
        case .critical:
            return "The Apple TV is hot; new software transcodes should pause."
        }
    }

    public var thermalWarning: String? {
        guard thermalState >= .serious else {
            return nil
        }
        return thermalExplanation
    }

    // MARK: - Path lock

    /// Whether a saved lock already pins playback to this plan's rung.
    public var isPathLocked: Bool {
        preferences.maximumRung == plan.rung
    }

    public var lockActionTitle: String {
        isPathLocked ? "Path locked" : "Lock this path"
    }

    /// Locks playback to the current rung for the caller's source/codec scope.
    ///
    /// The returned preferences should be persisted by the caller alongside the
    /// source and codec so the planner applies the same cap on future items.
    @discardableResult
    public mutating func lockPath() -> PlaybackPreferences {
        preferences.maximumRung = plan.rung
        return preferences
    }

    /// Removes the saved path lock.
    @discardableResult
    public mutating func unlockPath() -> PlaybackPreferences {
        preferences.maximumRung = nil
        return preferences
    }

    // MARK: - Descriptions

    public var colorExplanation: String {
        let input = Self.hdrName(plan.video.inputHDR)
        let output = Self.hdrName(plan.video.outputHDR)
        switch plan.video.colorTransform {
        case .none:
            return "\(input) passes through unchanged."
        case .systemToneMap:
            return "\(input) is tone-mapped to \(output) by the system compositor."
        case .stripDolbyVisionRPU:
            return "The Dolby Vision RPU is stripped and the base layer is presented as \(output)."
        case .dolbyVisionMetadataConversion:
            return "Dolby Vision metadata is converted to \(output) without re-encoding the picture."
        case .explicitToneMap:
            return "\(input) → \(output) tone-mapped at \(Int(preferences.targetPeakNits)) nits."
        case .hlgToSDR:
            return "HLG → \(output) tone-mapped at \(Int(preferences.targetPeakNits)) nits."
        }
    }

    public var resolutionName: String {
        let width = plan.video.width
        let height = plan.video.height
        guard width > 0, height > 0 else {
            return "unknown resolution"
        }
        let label: String
        switch height {
        case 2_160...:
            label = "4K"
        case 1_080...:
            label = "1080p"
        case 720...:
            label = "720p"
        default:
            label = "SD"
        }
        return "\(width)×\(height) \(label)"
    }

    public var decodeDescription: String {
        switch plan.video.decodePath {
        case .hardware:
            return "Hardware"
        case .software:
            return "Software"
        case .none:
            return plan.isServerTranscode ? "Server" : "Unsupported"
        }
    }

    public var decodeExplanation: String? {
        switch plan.video.decodePath {
        case .hardware:
            return "Decoded by the Apple TV media engine."
        case .software:
            return "Decoded on the CPU; thermal pressure may lower resolution."
        case .none:
            return plan.isServerTranscode
                ? "The server produces the stream."
                : "No decoder is available for this codec."
        }
    }

    private var usesToneMapping: Bool {
        switch plan.video.colorTransform {
        case .explicitToneMap, .hlgToSDR:
            return true
        default:
            return false
        }
    }

    // MARK: - Naming

    static func codecName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "h264", "avc":
            return "H.264"
        case "hevc", "h265":
            return "HEVC"
        case "av1":
            return "AV1"
        case "vp8":
            return "VP8"
        case "vp9":
            return "VP9"
        case "vvc", "h266":
            return "VVC"
        case "mpeg1":
            return "MPEG-1"
        case "mpeg2":
            return "MPEG-2"
        case "vc1":
            return "VC-1"
        case "wmv3":
            return "WMV3"
        case "divx":
            return "DivX"
        case "aac":
            return "AAC"
        case "ac3":
            return "AC-3"
        case "eac3":
            return "E-AC-3"
        case "truehd":
            return "TrueHD"
        case "dts":
            return "DTS"
        case "dts-hd":
            return "DTS-HD"
        case "flac":
            return "FLAC"
        case "alac":
            return "ALAC"
        case "mp3":
            return "MP3"
        case "opus":
            return "Opus"
        case "vorbis":
            return "Vorbis"
        case "pcm":
            return "PCM"
        case "wma":
            return "WMA"
        case "server":
            return "Server stream"
        case "none":
            return "None"
        default:
            return raw.uppercased()
        }
    }

    static func hdrName(_ format: HDRFormat) -> String {
        switch format {
        case .sdr:
            return "SDR"
        case .hdr10:
            return "HDR10"
        case .hdr10Plus:
            return "HDR10+"
        case .hlg:
            return "HLG"
        case .dolbyVision5:
            return "Dolby Vision Profile 5"
        case .dolbyVision8:
            return "Dolby Vision Profile 8"
        case .dolbyVision81:
            return "Dolby Vision Profile 8.1"
        }
    }

    static func routeName(_ route: AudioRoute) -> String {
        switch route {
        case .passthrough:
            return "Pass-through"
        case .nativeDecode:
            return "Native decode"
        case .softwareDecode:
            return "Software decode"
        case .downmixToStereo:
            return "Downmix to stereo"
        case .downmixTo51:
            return "Downmix to 5.1"
        }
    }

    static func biasName(_ bias: PlaybackPreferences.QualityBias) -> String {
        switch bias {
        case .bestQuality:
            return "Best quality"
        case .balanced:
            return "Balanced"
        case .lowestCPU:
            return "Lowest CPU"
        }
    }
}

private extension AudioPipelinePlan {
    var routeExplanation: String {
        switch route {
        case .passthrough:
            return "Sent to the receiver without decoding."
        case .nativeDecode:
            return "Decoded by the Apple TV audio engine."
        case .softwareDecode:
            return "Decoded on the CPU."
        case .downmixToStereo:
            return "Decoded and folded to two channels."
        case .downmixTo51:
            return "Decoded and folded to 5.1 channels."
        }
    }
}
