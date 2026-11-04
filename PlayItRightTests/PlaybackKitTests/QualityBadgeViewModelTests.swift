import CoreKit
import Foundation
import Testing
@testable import PlaybackKit

// MARK: - Fixtures

private func makeVideoPlan(
    rung: PipelineRung,
    inputCodec: String = "hevc",
    outputCodec: String = "hevc",
    inputHDR: HDRFormat = .hdr10,
    outputHDR: HDRFormat = .hdr10,
    colorTransform: ColorTransform = .none,
    decodePath: VideoDecodePath = .hardware
) -> VideoPipelinePlan {
    VideoPipelinePlan(
        inputCodec: inputCodec,
        outputCodec: outputCodec,
        inputContainer: .mkv,
        outputContainer: rung == .r1Direct ? .mkv : .mp4,
        decodePath: decodePath,
        colorTransform: colorTransform,
        inputHDR: inputHDR,
        outputHDR: outputHDR,
        bitDepth: 10,
        width: 3_840,
        height: 2_160
    )
}

private func makePlan(
    rung: PipelineRung,
    badge: QualityBadge? = nil,
    video: VideoPipelinePlan? = nil,
    audio: AudioPipelinePlan? = nil,
    reasons: [String] = [],
    isPlayable: Bool = true,
    isServerTranscode: Bool = false,
    rungCapApplied: Bool = false
) -> PipelinePlan {
    PipelinePlan(
        rung: rung,
        badge: badge ?? QualityBadge.forRung(rung),
        video: video ?? makeVideoPlan(rung: rung),
        audio: audio,
        reasons: reasons,
        isPlayable: isPlayable,
        isServerTranscode: isServerTranscode,
        rungCapApplied: rungCapApplied
    )
}

// MARK: - Tests

@Suite("QualityBadgeViewModel Tests")
struct QualityBadgeViewModelTests {
    @Test("Every rung maps to its honest badge label and color")
    func badgeForAllRungs() {
        let expected: [(PipelineRung, String, BadgeColor)] = [
            (.r1Direct, "Direct", .green),
            (.r2Remux, "Remuxed", .blue),
            (.r3HardwareTranscode, "Transcoded · HW", .amber),
            (.r4SoftwareTranscode, "Transcoded · SW", .orange),
            (.r5ServerTranscode, "Server", .gray)
        ]

        for (rung, label, color) in expected {
            let viewModel = QualityBadgeViewModel(
                plan: makePlan(
                    rung: rung,
                    isServerTranscode: rung == .r5ServerTranscode
                )
            )
            #expect(viewModel.label == label)
            #expect(viewModel.color == color)
            #expect(viewModel.badge == QualityBadge.forRung(rung))
        }
    }

    @Test("Each rung has a plain-language summary")
    func summaryForAllRungs() {
        let expected: [PipelineRung: String] = [
            .r1Direct: "Direct play — no conversion.",
            .r2Remux: "Remuxed to MP4 — picture untouched.",
            .r3HardwareTranscode: "Transcoded on this Apple TV using hardware.",
            .r4SoftwareTranscode: "Transcoded on this Apple TV in software.",
            .r5ServerTranscode: "Transcoded by your server."
        ]

        for (rung, summary) in expected {
            let viewModel = QualityBadgeViewModel(
                plan: makePlan(
                    rung: rung,
                    isServerTranscode: rung == .r5ServerTranscode
                )
            )
            #expect(viewModel.summary == summary)
        }
    }

    @Test("Dolby Vision to SDR tone-map is explained in plain language")
    func dolbyVisionToSDRExplanation() {
        let video = makeVideoPlan(
            rung: .r3HardwareTranscode,
            inputCodec: "hevc",
            outputCodec: "hevc",
            inputHDR: .dolbyVision8,
            outputHDR: .sdr,
            colorTransform: .explicitToneMap,
            decodePath: .hardware
        )
        let viewModel = QualityBadgeViewModel(
            plan: makePlan(rung: .r3HardwareTranscode, video: video),
            preferences: PlaybackPreferences(
                colorMode: .precise,
                targetPeakNits: 100
            )
        )

        let explanation = viewModel.colorExplanation
        #expect(explanation.contains("Dolby Vision Profile 8"))
        #expect(explanation.contains("SDR"))
        #expect(explanation.contains("→"))
        #expect(explanation.contains("100 nits"))
        #expect(explanation.contains("tone-mapped"))

        let color = viewModel.colorSection
        #expect(color.rows.first?.value == ColorTransform.explicitToneMap.displayName)
        #expect(color.rows.contains { $0.title == "Tone-map target" && $0.value == "100 nits" })
        #expect(viewModel.technicalSummary.contains("Dolby Vision Profile 8"))
    }

    @Test("Technical drill-down covers video, color, audio, and device rows")
    func technicalDrillDown() {
        let audio = AudioPipelinePlan(
            inputCodec: "eac3",
            outputCodec: "pcm",
            route: .downmixToStereo,
            channels: 8,
            outputChannels: 2,
            isAtmos: false,
            language: "eng"
        )
        let viewModel = QualityBadgeViewModel(
            plan: makePlan(
                rung: .r4SoftwareTranscode,
                video: makeVideoPlan(
                    rung: .r4SoftwareTranscode,
                    inputCodec: "av1",
                    outputCodec: "h264",
                    decodePath: .software
                ),
                audio: audio
            )
        )

        let titles = viewModel.sections.map(\.title)
        #expect(titles == ["Video", "Color", "Audio", "Device"])

        let video = viewModel.videoSection
        #expect(video.rows.contains { $0.title == "Input" && $0.value.contains("AV1") && $0.value.contains("MKV") })
        #expect(video.rows.contains { $0.title == "Output" && $0.value.contains("H.264") && $0.value.contains("MP4") })
        #expect(video.rows.contains { $0.title == "Decode" && $0.value == "Software" })

        let audioSection = try? #require(viewModel.sections.first { $0.title == "Audio" })
        #expect(audioSection?.rows.contains { $0.title == "Route" && $0.value == "Downmix to stereo" } == true)
        #expect(audioSection?.rows.contains { $0.title == "Output" && $0.value.contains("2ch") } == true)
    }

    @Test("Planner reasons are exposed verbatim for the Why list")
    func reasonsAreExposed() {
        let reasons = [
            "Dolby Vision Profile 8 RPU is stripped and the base HEVC layer is presented as HDR10.",
            "E-AC-3 is passed through to the receiver."
        ]
        let viewModel = QualityBadgeViewModel(
            plan: makePlan(rung: .r2Remux, reasons: reasons)
        )

        #expect(viewModel.reasons == reasons)
    }

    @Test("Thermal state is reported in plain language and warns when hot")
    func thermalStateReporting() {
        let cool = QualityBadgeViewModel(
            plan: makePlan(rung: .r1Direct),
            thermalState: .nominal
        )
        #expect(cool.thermalStateName == "Nominal")
        #expect(cool.thermalWarning == nil)

        let fair = QualityBadgeViewModel(
            plan: makePlan(rung: .r1Direct),
            thermalState: .fair
        )
        #expect(fair.thermalWarning == nil)

        let serious = QualityBadgeViewModel(
            plan: makePlan(rung: .r4SoftwareTranscode),
            thermalState: .serious
        )
        #expect(serious.thermalStateName == "Serious")
        #expect(serious.thermalWarning?.contains("1080p") == true)

        let critical = QualityBadgeViewModel(
            plan: makePlan(rung: .r4SoftwareTranscode),
            thermalState: .critical
        )
        #expect(critical.thermalWarning?.contains("hot") == true)
    }

    @Test("Lock this path pins the current rung in preferences")
    func lockPath() {
        var viewModel = QualityBadgeViewModel(
            plan: makePlan(rung: .r3HardwareTranscode)
        )
        #expect(!viewModel.isPathLocked)
        #expect(viewModel.lockActionTitle == "Lock this path")

        let locked = viewModel.lockPath()
        #expect(locked.maximumRung == .r3HardwareTranscode)
        #expect(viewModel.preferences.maximumRung == .r3HardwareTranscode)
        #expect(viewModel.isPathLocked)
        #expect(viewModel.lockActionTitle == "Path locked")

        let unlocked = viewModel.unlockPath()
        #expect(unlocked.maximumRung == nil)
        #expect(!viewModel.isPathLocked)
    }

    @Test("A shown quality lock is called out in the video section")
    func rungCapIsExplained() {
        let viewModel = QualityBadgeViewModel(
            plan: makePlan(
                rung: .r2Remux,
                reasons: ["Quality lock caps this item at Remux."],
                rungCapApplied: true
            )
        )

        #expect(
            viewModel.videoSection.rows.contains {
                $0.title == "Quality lock"
                    && $0.value == "Capped at Remux"
            }
        )
    }

    @Test("An unplayable plan is reported honestly")
    func unplayablePlan() {
        let viewModel = QualityBadgeViewModel(
            plan: makePlan(
                rung: .r4SoftwareTranscode,
                video: makeVideoPlan(
                    rung: .r4SoftwareTranscode,
                    decodePath: .none
                ),
                isPlayable: false
            )
        )

        #expect(viewModel.summary == "This file cannot be played on this Apple TV.")
        #expect(viewModel.decodeDescription == "Unsupported")
    }

    @Test("Server transcode is labelled as a server path")
    func serverTranscode() {
        let viewModel = QualityBadgeViewModel(
            plan: makePlan(
                rung: .r5ServerTranscode,
                video: makeVideoPlan(
                    rung: .r5ServerTranscode,
                    outputCodec: "server",
                    decodePath: .none
                ),
                isServerTranscode: true
            )
        )

        #expect(viewModel.decodeDescription == "Server")
        #expect(viewModel.decodeExplanation?.contains("server") == true)
        #expect(viewModel.summary == "Transcoded by your server.")
    }
}
