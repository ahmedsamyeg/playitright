import CapKit
import Foundation

/// Chooses the cheapest feasible playback path for a probed file (PB-G2/PB-G3).
///
/// Color and audio are decided independently. The rung is driven by the video
/// path (container, hardware decode, color transform); audio resolution can
/// force software decoding or a downmix without changing the rung. A user rung
/// cap only applies when that lower rung is still feasible.
public struct PipelinePlanner: Sendable {
    public let capabilities: CapabilityRegistry

    public init(capabilities: CapabilityRegistry) {
        self.capabilities = capabilities
    }

    public func plan(
        graph: MediaGraph,
        sink: SinkProfile,
        preferences: PlaybackPreferences = PlaybackPreferences(),
        serverTranscodeAvailable: Bool = false
    ) -> PipelinePlan {
        let video = graph.primaryVideoTrack
        let capabilitiesVideoCodec = video.flatMap {
            Self.capabilityCodec(for: $0.codec)
        }
        let bitDepth = video?.bitDepth ?? 8
        let resolution = VideoResolution(
            width: max(1, video?.width ?? 1_920),
            height: max(1, video?.height ?? 1_080)
        )
        let dolbyVisionProfile = graph.hdrFormat.dolbyVisionProfileValue
        let decodePath = Self.decodePath(
            codec: capabilitiesVideoCodec,
            bitDepth: bitDepth,
            resolution: resolution,
            dolbyVisionProfile: dolbyVisionProfile,
            capabilities: capabilities
        )
        let color = colorDecision(
            graph: graph,
            sink: sink,
            preferences: preferences,
            decodePath: decodePath
        )

        var reasons = color.reasons
        if graph.container.isAVFoundationNative {
            reasons.insert(
                "\(graph.container.rawValue.uppercased()) is demuxed natively by AVFoundation.",
                at: 0
            )
        } else {
            reasons.insert(
                "\(graph.container.rawValue.uppercased()) is demuxed by FFmpeg and remuxed to fMP4.",
                at: 0
            )
        }

        let requiredRung = requiredRung(
            graph: graph,
            decodePath: decodePath,
            color: color,
            serverTranscodeAvailable: serverTranscodeAvailable,
            preferences: preferences
        )

        let selection = applyRungCap(
            required: requiredRung,
            decodePath: decodePath,
            color: color,
            serverTranscodeAvailable: serverTranscodeAvailable,
            preferences: preferences
        )

        var selectedRung = selection.rung
        var capApplied = selection.capApplied
        var selectedColor = color
        if capApplied && selectedRung.rank < requiredRung.rank {
            // A cap may trade an explicit tone-map for the system tone-map,
            // but only if the picture can still be presented.
            selectedColor = color.withFallbackTransform()
            reasons.append(
                "Quality lock caps this item at \(selectedRung.displayName); system tone-mapping is used to avoid transcoding."
            )
        }

        if selectedRung == .r5ServerTranscode {
            reasons.append(
                "Remote transcode was chosen because the server offers it and local playback would need software transcoding."
            )
        }

        let audio = audioPlan(
            track: graph.defaultAudioTrack,
            sink: sink,
            capabilities: capabilities,
            reasons: &reasons
        )

        let isPlayable = decodePath != .none
            && color.isPlayable
            && (audio?.isPlayable ?? true)
        if !isPlayable {
            reasons.append(
                "This file cannot be played with the current device and sink capabilities."
            )
        }

        let videoPlan = VideoPipelinePlan(
            inputCodec: video?.codec.rawValue ?? "none",
            outputCodec: outputVideoCodec(
                rung: selectedRung,
                decodePath: decodePath,
                sourceCodec: video?.codec
            ),
            inputContainer: graph.container,
            outputContainer: selectedRung == .r1Direct
                ? graph.container
                : .mp4,
            decodePath: selectedRung == .r5ServerTranscode
                ? .none
                : decodePath,
            colorTransform: selectedColor.transform,
            inputHDR: graph.hdrFormat,
            outputHDR: selectedColor.outputHDR,
            bitDepth: bitDepth,
            width: video?.width ?? 0,
            height: video?.height ?? 0
        )

        return PipelinePlan(
            rung: selectedRung,
            badge: QualityBadge.forRung(selectedRung),
            video: videoPlan,
            audio: audio?.plan,
            reasons: reasons,
            isPlayable: isPlayable,
            isServerTranscode: selectedRung == .r5ServerTranscode,
            colorMode: preferences.colorMode,
            qualityBias: preferences.qualityBias,
            rungCapApplied: capApplied
        )
    }

    // MARK: - Color

    private struct ColorDecision {
        var transform: ColorTransform
        var outputHDR: HDRFormat
        var minimumRungRank: Int
        var isPlayable: Bool
        var reasons: [String]

        func withFallbackTransform() -> ColorDecision {
            var copy = self
            if transform == .explicitToneMap
                || transform == .hlgToSDR
                || transform == .dolbyVisionMetadataConversion {
                copy.transform = .systemToneMap
                copy.outputHDR = .sdr
                copy.minimumRungRank = 0
            }
            return copy
        }
    }

    private func colorDecision(
        graph: MediaGraph,
        sink: SinkProfile,
        preferences: PlaybackPreferences,
        decodePath: VideoDecodePath
    ) -> ColorDecision {
        let contentHDR = graph.hdrFormat
        let display = sink.display
        var reasons: [String] = []

        if contentHDR == .sdr {
            reasons.append("SDR source passes through unchanged.")
            return ColorDecision(
                transform: .none,
                outputHDR: .sdr,
                minimumRungRank: 0,
                isPlayable: true,
                reasons: reasons
            )
        }

        if contentHDR.isDolbyVision {
            let profile = contentHDR.dolbyVisionProfile ?? 8
            if display.supportsDolbyVision,
               capabilities.supportsDolbyVision(profile: Double(profile)) {
                reasons.append(
                    "\(contentHDR.rawValue) is presented directly by the Dolby Vision display."
                )
                return ColorDecision(
                    transform: .none,
                    outputHDR: contentHDR,
                    minimumRungRank: 0,
                    isPlayable: true,
                    reasons: reasons
                )
            }

            if display.supportsHDR10 {
                if profile == 5 {
                    reasons.append(
                        "Dolby Vision Profile 5 is converted to HDR10 metadata without re-encoding the picture."
                    )
                    return ColorDecision(
                        transform: .dolbyVisionMetadataConversion,
                        outputHDR: .hdr10,
                        minimumRungRank: 3,
                        isPlayable: true,
                        reasons: reasons
                    )
                }
                reasons.append(
                    "Dolby Vision Profile \(profile) RPU is stripped and the base HEVC layer is presented as HDR10."
                )
                return ColorDecision(
                    transform: .stripDolbyVisionRPU,
                    outputHDR: .hdr10,
                    minimumRungRank: 2,
                    isPlayable: true,
                    reasons: reasons
                )
            }

            if preferences.colorMode == .precise {
                reasons.append(
                    "Dolby Vision is explicitly tone-mapped to SDR at \(Int(preferences.targetPeakNits)) nits."
                )
                return ColorDecision(
                    transform: .explicitToneMap,
                    outputHDR: .sdr,
                    minimumRungRank: 3,
                    isPlayable: true,
                    reasons: reasons
                )
            }

            reasons.append(
                "Dolby Vision is tone-mapped to SDR by the system compositor."
            )
            return ColorDecision(
                transform: .systemToneMap,
                outputHDR: .sdr,
                minimumRungRank: decodePath == .software ? 4 : 0,
                isPlayable: true,
                reasons: reasons
            )
        }

        // HDR10 / HDR10+ / HLG
        if display.supportsHDR10 || (contentHDR == .hlg && display.supportsHLG) {
            reasons.append(
                "\(contentHDR.rawValue) is passed through to the HDR display."
            )
            return ColorDecision(
                transform: .none,
                outputHDR: contentHDR == .hdr10Plus ? .hdr10 : contentHDR,
                minimumRungRank: 0,
                isPlayable: true,
                reasons: reasons
            )
        }

        if preferences.colorMode == .precise {
            let transform: ColorTransform = contentHDR == .hlg
                ? .hlgToSDR
                : .explicitToneMap
            reasons.append(
                "\(contentHDR.rawValue) is explicitly tone-mapped to SDR at \(Int(preferences.targetPeakNits)) nits."
            )
            return ColorDecision(
                transform: transform,
                outputHDR: .sdr,
                minimumRungRank: 3,
                isPlayable: true,
                reasons: reasons
            )
        }

        reasons.append(
            "\(contentHDR.rawValue) is tone-mapped to SDR by the system compositor."
        )
        return ColorDecision(
            transform: .systemToneMap,
            outputHDR: .sdr,
            minimumRungRank: decodePath == .software ? 4 : 0,
            isPlayable: true,
            reasons: reasons
        )
    }

    // MARK: - Rung selection

    private func requiredRung(
        graph: MediaGraph,
        decodePath: VideoDecodePath,
        color: ColorDecision,
        serverTranscodeAvailable: Bool,
        preferences: PlaybackPreferences
    ) -> PipelineRung {
        if decodePath == .none {
            return serverTranscodeAvailable
                ? .r5ServerTranscode
                : .r4SoftwareTranscode
        }

        if decodePath == .software {
            if serverTranscodeAvailable && preferences.preferServerTranscode {
                return .r5ServerTranscode
            }
            return .r4SoftwareTranscode
        }

        // Hardware decode.
        if color.minimumRungRank >= 3 {
            return .r3HardwareTranscode
        }
        if color.minimumRungRank == 2 {
            return .r2Remux
        }
        if graph.container.isAVFoundationNative {
            return .r1Direct
        }
        return .r2Remux
    }

    private struct RungSelection {
        var rung: PipelineRung
        var capApplied: Bool
    }

    private func applyRungCap(
        required: PipelineRung,
        decodePath: VideoDecodePath,
        color: ColorDecision,
        serverTranscodeAvailable: Bool,
        preferences: PlaybackPreferences
    ) -> RungSelection {
        guard let cap = preferences.maximumRung,
              required > cap else {
            return RungSelection(rung: required, capApplied: false)
        }

        let feasible: Bool
        switch cap {
        case .r1Direct:
            feasible = required == .r1Direct
        case .r2Remux:
            feasible = decodePath == .hardware
        case .r3HardwareTranscode:
            feasible = decodePath == .hardware
        case .r4SoftwareTranscode:
            feasible = decodePath != .none
        case .r5ServerTranscode:
            feasible = serverTranscodeAvailable
        }

        return feasible
            ? RungSelection(rung: cap, capApplied: true)
            : RungSelection(rung: required, capApplied: false)
    }

    // MARK: - Audio

    private struct ResolvedAudio {
        var plan: AudioPipelinePlan
        var isPlayable: Bool
    }

    private func audioPlan(
        track: AudioTrackInfo?,
        sink: SinkProfile,
        capabilities: CapabilityRegistry,
        reasons: inout [String]
    ) -> ResolvedAudio? {
        guard let track else {
            reasons.append("The file has no audio track.")
            return nil
        }

        let capability = Self.capabilityCodec(for: track.codec)
            .flatMap { capabilities.profile.audioCapability(for: $0) }
        let canPassthrough = sink.audio.canPassthrough(track.codec)
            && (capability?.passthrough ?? true)
            && (!track.isAtmos || sink.audio.supportsAtmos)

        if canPassthrough {
            reasons.append(
                "\(track.codec.rawValue.uppercased()) is passed through to \(sink.audio.setup.displayName)."
            )
            return ResolvedAudio(
                plan: AudioPipelinePlan(
                    inputCodec: track.codec.rawValue,
                    outputCodec: track.codec.rawValue,
                    route: .passthrough,
                    channels: track.channels,
                    outputChannels: track.channels,
                    isAtmos: track.isAtmos,
                    language: track.language
                ),
                isPlayable: true
            )
        }

        let hardwareDecode = capability?.hardwareDecode ?? false
        let softwareDecode = capability?.softwareDecode ?? false
        guard hardwareDecode || softwareDecode else {
            reasons.append(
                "The \(track.codec.rawValue.uppercased()) audio track cannot be decoded by this device."
            )
            return ResolvedAudio(
                plan: AudioPipelinePlan(
                    inputCodec: track.codec.rawValue,
                    outputCodec: "unsupported",
                    route: .softwareDecode,
                    channels: track.channels,
                    outputChannels: 0,
                    isAtmos: track.isAtmos,
                    language: track.language
                ),
                isPlayable: false
            )
        }

        let maxChannels = sink.audio.maxChannels
        if track.channels > maxChannels {
            let stereo = maxChannels <= 2
            let route: AudioRoute = stereo ? .downmixToStereo : .downmixTo51
            let outputChannels = stereo ? 2 : min(maxChannels, 6)
            reasons.append(
                "\(track.channels)ch \(track.codec.rawValue.uppercased()) is decoded and downmixed to \(outputChannels)ch."
            )
            return ResolvedAudio(
                plan: AudioPipelinePlan(
                    inputCodec: track.codec.rawValue,
                    outputCodec: "pcm",
                    route: route,
                    channels: track.channels,
                    outputChannels: outputChannels,
                    isAtmos: false,
                    language: track.language
                ),
                isPlayable: true
            )
        }

        let route: AudioRoute = hardwareDecode ? .nativeDecode : .softwareDecode
        reasons.append(
            "\(track.codec.rawValue.uppercased()) is \(route == .nativeDecode ? "decoded natively" : "decoded in software")."
        )
        return ResolvedAudio(
            plan: AudioPipelinePlan(
                inputCodec: track.codec.rawValue,
                outputCodec: "pcm",
                route: route,
                channels: track.channels,
                outputChannels: track.channels,
                isAtmos: track.isAtmos,
                language: track.language
            ),
            isPlayable: true
        )
    }

    // MARK: - Mapping

    private static func decodePath(
        codec: CapKit.VideoCodec?,
        bitDepth: Int,
        resolution: VideoResolution,
        dolbyVisionProfile: Double?,
        capabilities: CapabilityRegistry
    ) -> VideoDecodePath {
        guard let codec else {
            return .none
        }
        switch capabilities.decodePath(
            codec: codec,
            bitDepth: bitDepth,
            resolution: resolution,
            dolbyVisionProfile: dolbyVisionProfile
        ) {
        case .hardware:
            return .hardware
        case .software:
            return .software
        case .unsupported:
            return .none
        }
    }

    private func outputVideoCodec(
        rung: PipelineRung,
        decodePath: VideoDecodePath,
        sourceCodec: VideoCodec?
    ) -> String {
        switch rung {
        case .r1Direct, .r2Remux:
            return sourceCodec?.rawValue ?? "none"
        case .r3HardwareTranscode:
            return capabilities.canHardwareEncode(
                codec: .hevc,
                bitDepth: 10
            ) ? "hevc" : "h264"
        case .r4SoftwareTranscode:
            return "h264"
        case .r5ServerTranscode:
            return "server"
        }
    }

    private static func capabilityCodec(
        for codec: VideoCodec
    ) -> CapKit.VideoCodec? {
        switch codec {
        case .h264:
            return .h264
        case .hevc:
            return .hevc
        case .av1:
            return .av1
        case .vp8, .vp9:
            return .vp9
        case .vvc:
            return .vvc
        case .mpeg1, .mpeg2:
            return .mpeg2
        case .vc1:
            return .vc1
        case .wmv3:
            return .wmv
        case .divx:
            return .divx
        case .other:
            return nil
        }
    }

    private static func capabilityCodec(
        for codec: AudioCodec
    ) -> CapKit.AudioCodec? {
        switch codec {
        case .aac:
            return .aac
        case .ac3:
            return .ac3
        case .eac3:
            return .eac3
        case .truehd:
            return .truehd
        case .dts, .dtsHD:
            return .dts
        case .flac:
            return .flac
        case .alac:
            return .alac
        case .mp3:
            return .mp3
        case .opus:
            return .opus
        case .vorbis:
            return .vorbis
        case .pcm:
            return .pcm
        case .wma, .other:
            return nil
        }
    }
}
