import CoreKit
import Foundation
import PlaybackKit
import Testing
@testable import PlayItRight

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
    video: VideoPipelinePlan? = nil,
    audio: AudioPipelinePlan? = nil,
    reasons: [String] = [],
    isPlayable: Bool = true,
    isServerTranscode: Bool = false,
    rungCapApplied: Bool = false
) -> PipelinePlan {
    PipelinePlan(
        rung: rung,
        badge: QualityBadge.forRung(rung),
        video: video ?? makeVideoPlan(rung: rung),
        audio: audio,
        reasons: reasons,
        isPlayable: isPlayable,
        isServerTranscode: isServerTranscode,
        rungCapApplied: rungCapApplied
    )
}

/// In-memory store so the lock/unlock action can be asserted directly.
private final class SpyPreferencesStore: PlaybackPreferencesStore {
    var initial: PlaybackPreferences
    private(set) var saved: [(preferences: PlaybackPreferences, sourceId: String?, codec: String?)] = []

    init(initial: PlaybackPreferences = PlaybackPreferences()) {
        self.initial = initial
    }

    func load(sourceId: String?, codec: String?) -> PlaybackPreferences {
        initial
    }

    func save(
        _ preferences: PlaybackPreferences,
        sourceId: String?,
        codec: String?
    ) {
        saved.append((preferences, sourceId, codec))
    }
}

// MARK: - Tests

@MainActor
@Suite("PipelineDetailSheet Tests")
struct PipelineDetailSheetTests {
    @Test("The sheet explains R1 through R5 honestly")
    func rungExplanations() {
        let expectations: [(PipelineRung, String, String)] = [
            (.r1Direct, "Direct", "Direct play — no conversion."),
            (.r2Remux, "Remuxed", "Remuxed to MP4 — picture untouched."),
            (
                .r3HardwareTranscode,
                "Transcoded · HW",
                "Transcoded on this Apple TV using hardware."
            ),
            (
                .r4SoftwareTranscode,
                "Transcoded · SW",
                "Transcoded on this Apple TV in software."
            ),
            (.r5ServerTranscode, "Server", "Transcoded by your server.")
        ]

        for (rung, label, summary) in expectations {
            let store = SpyPreferencesStore()
            let viewModel = PipelineDetailSheetViewModel(
                plan: makePlan(
                    rung: rung,
                    isServerTranscode: rung == .r5ServerTranscode
                ),
                store: store
            )

            #expect(viewModel.label == label)
            #expect(viewModel.summary == summary)
            #expect(viewModel.sections.map(\.title).first == "Video")

            let pathRow = viewModel.sections
                .first { $0.title == "Video" }?
                .rows.first { $0.title == "Path" }
            #expect(pathRow?.value == rung.displayName)
            #expect(pathRow?.explanation == summary)
        }
    }

    @Test("The sheet includes decode, color, audio, and thermal details")
    func technicalSections() {
        let audio = AudioPipelinePlan(
            inputCodec: "truehd",
            outputCodec: "pcm",
            route: .downmixTo51,
            channels: 8,
            outputChannels: 6,
            isAtmos: true,
            language: "eng"
        )
        let viewModel = PipelineDetailSheetViewModel(
            plan: makePlan(
                rung: .r4SoftwareTranscode,
                video: makeVideoPlan(
                    rung: .r4SoftwareTranscode,
                    inputCodec: "av1",
                    outputCodec: "h264",
                    inputHDR: .dolbyVision8,
                    outputHDR: .sdr,
                    colorTransform: .explicitToneMap,
                    decodePath: .software
                ),
                audio: audio,
                reasons: ["AV1 has no hardware decoder on this Apple TV."]
            ),
            thermalState: .serious,
            store: SpyPreferencesStore()
        )

        #expect(viewModel.sections.map(\.title) == ["Video", "Color", "Audio", "Device"])
        #expect(viewModel.reasons.first?.contains("AV1") == true)
        #expect(viewModel.thermalWarning?.contains("1080p") == true)

        let audioSection = viewModel.sections.first { $0.title == "Audio" }
        #expect(audioSection?.rows.contains { $0.value == "Downmix to 5.1" } == true)
        #expect(audioSection?.rows.contains { $0.value == "Dolby Atmos metadata carried" } == true)
    }

    @Test("Locking the path updates and persists planner preferences")
    func lockPathUpdatesPlannerPreferences() {
        let store = SpyPreferencesStore()
        let viewModel = PipelineDetailSheetViewModel(
            plan: makePlan(rung: .r3HardwareTranscode),
            sourceId: "source-1",
            codec: "hevc",
            store: store
        )

        #expect(viewModel.isPathLocked == false)
        #expect(viewModel.lockActionTitle == "Lock this path")

        let locked = viewModel.lockPath()
        #expect(locked.maximumRung == .r3HardwareTranscode)
        #expect(viewModel.preferences.maximumRung == .r3HardwareTranscode)
        #expect(viewModel.isPathLocked)
        #expect(viewModel.lockActionTitle == "Path locked")

        let saved = try? #require(store.saved.last)
        #expect(saved?.preferences.maximumRung == .r3HardwareTranscode)
        #expect(saved?.sourceId == "source-1")
        #expect(saved?.codec == "hevc")

        let unlocked = viewModel.unlockPath()
        #expect(unlocked.maximumRung == nil)
        #expect(viewModel.isPathLocked == false)
        #expect(store.saved.last?.preferences.maximumRung == nil)
    }

    @Test("A stored lock is restored for the same source and codec")
    func lockIsRestored() {
        let store = SpyPreferencesStore(
            initial: PlaybackPreferences(
                maximumRung: .r2Remux,
                qualityBias: .lowestCPU,
                colorMode: .precise
            )
        )
        let viewModel = PipelineDetailSheetViewModel(
            plan: makePlan(rung: .r2Remux),
            sourceId: "source-1",
            codec: "hevc",
            store: store
        )

        #expect(viewModel.isPathLocked)
        #expect(viewModel.lockActionTitle == "Path locked")
        #expect(viewModel.sections.contains { section in
            section.rows.contains {
                $0.title == "Path lock" && $0.value == "Locked to Remux"
            }
        })
    }

    @Test("Toggling the lock alternates between lock and unlock")
    func toggleLock() {
        let store = SpyPreferencesStore()
        let viewModel = PipelineDetailSheetViewModel(
            plan: makePlan(rung: .r4SoftwareTranscode),
            sourceId: "source-1",
            codec: "av1",
            store: store
        )

        #expect(viewModel.togglePathLock().maximumRung == .r4SoftwareTranscode)
        #expect(viewModel.isPathLocked)
        #expect(viewModel.togglePathLock().maximumRung == nil)
        #expect(viewModel.isPathLocked == false)
        #expect(store.saved.count == 2)
    }

    @Test("The badge presents and dismisses the detail sheet")
    func sheetPresentationState() {
        let viewModel = PipelineDetailSheetViewModel(
            plan: makePlan(rung: .r1Direct),
            store: SpyPreferencesStore()
        )

        #expect(viewModel.isSheetPresented == false)
        viewModel.presentSheet()
        #expect(viewModel.isSheetPresented)
        viewModel.dismissSheet()
        #expect(viewModel.isSheetPresented == false)
    }
}
