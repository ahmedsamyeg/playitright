import Foundation
import Testing
@testable import PlaybackKit

/// HDR10+ DVM processing tests (TASK-4.2, PB-16, doc 04 §7).
@Suite
struct HDR10PlusProcessorTests {
    // MARK: - Fixtures

    /// A realistic single-window scene, values in the spec's 1/10000ths-of-a-nit coding.
    private static func sampleWindow(mode: HDR10PlusWindowMetadata.Mode) -> HDR10PlusWindowMetadata {
        HDR10PlusWindowMetadata(
            mode: mode,
            maxSCL: [(6_000, 1_500), (12_000, 6_000), (18_000, 10_000)],
            averageMaxRGB: [(60_000, 300), (120_000, 900), (130_000, 1_800)],
            brightPixelFraction: 12_000,
            distributionMaxRGB: [
                (0, 2_000),
                (1, 5_500),
                (2, 9_999)
            ],
            bezierAnchors: [153, 306, 459, 612, 714, 816, 900, 950, 1000, 1023],
            targetedDisplayPeakNits: 1_000_000,
            measuredPeakRows: [[9, 8, 7], [6, 5, 4]],
            saturationGainRows: [(0, 100), (50, 120)],
            midpointRows: [(10, 40), (60, 90)]
        )
    }

    private static var sampleFrame: HDR10PlusFrameMetadata {
        HDR10PlusFrameMetadata(
            applicationVersion: 1,
            windows: [sampleWindow(mode: .basic)]
        )
    }

    // MARK: - Roundtrip

    @Test
    func roundTripsSingleWindowPayload() throws {
        let frame = Self.sampleFrame
        let encoded = try HDR10PlusProcessor.encode(frame: frame)
        let decoded = try HDR10PlusProcessor.parse(metadataPayload: encoded)
        #expect(decoded == frame)
    }

    @Test
    func roundTripsExtendedModeAndSecondWindow() throws {
        let second = HDR10PlusWindowMetadata(
            upperLeftCornerX: 1_000,
            upperLeftCornerY: 2_000,
            lowerRightCornerX: 8_000,
            lowerRightCornerY: 9_000,
            mode: .extended,
            maxSCL: [(100, 400), (200, 800), (300, 1_600)],
            averageMaxRGB: [(100, 300), (200, 500), (300, 600)],
            brightPixelFraction: 1_500,
            distributionMaxRGB: [(0, 100), (1, 200), (2, 300)],
            bezierAnchors: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
            targetedDisplayPeakNits: 500_000
        )
        let frame = HDR10PlusFrameMetadata(
            applicationVersion: 1,
            windows: [Self.sampleWindow(mode: .extended), second]
        )
        let decoded = try HDR10PlusProcessor.parse(
            metadataPayload: try HDR10PlusProcessor.encode(frame: frame)
        )
        #expect(decoded == frame)
    }

    // MARK: - Rejects malformed payloads

    @Test
    func rejectsEmptyPayload() {
        #expect(performing: {
            _ = try HDR10PlusProcessor.parse(metadataPayload: [])
        }, throws: { error in
            String(describing: error).contains("emptyPayload")
        })
    }

    @Test
    func rejectsWrongApplicationIdentifier() {
        #expect(performing: {
            _ = try HDR10PlusProcessor.parse(metadataPayload: [0x03])
        }, throws: { error in
            String(describing: error).contains("unsupportedApplicationIdentifier")
        })
    }

    @Test
    func rejectsTruncatedPayload() throws {
        let encoded = try HDR10PlusProcessor.encode(frame: Self.sampleFrame)
        let half = Array(encoded.prefix(encoded.count / 2))
        var caught: Error?
        do {
            _ = try HDR10PlusProcessor.parse(metadataPayload: half)
        } catch {
            caught = error
        }
        let captured = try #require(caught)
        var matchedTruncation = false
        if case HDR10PlusProcessorError.truncatedPayload = captured {
            matchedTruncation = true
        }
        #expect(matchedTruncation)
    }

    // MARK: - SEI envelope

    @Test
    func parsesSyntheticHDR10PlusClipSEI() throws {
        // "Conformance clip": wrap the reference scene in the ITU-T T.35
        // user-data-registered SEI envelope, like a real HEVC/H.264 stream
        // carries it, and verify extraction end to end.
        let nal = try HDR10PlusProcessor.seiNALUnit(from: Self.sampleFrame)
        let decoded = try HDR10PlusProcessor.parse(seiNALUnit: nal)
        #expect(decoded == Self.sampleFrame)
    }

    @Test
    func rejectsNonT35ProviderPayload() throws {
        // Type 4 SEI but a random provider organization: not HDR10+.
        let nal: [UInt8] = [0x04, 0x07, 0x99, 0x88, 0x77, 0x01, 0x02, 0x03, 0x04]
        var caught: Error?
        do {
            _ = try HDR10PlusProcessor.parse(seiNALUnit: nal)
        } catch {
            caught = error
        }
        let captured = try #require(caught)
        var matchedNotHDR10Plus = false
        if case HDR10PlusProcessorError.notAHDR10PlusPayload = captured {
            matchedNotHDR10Plus = true
        }
        #expect(matchedNotHDR10Plus)
    }

    // MARK: - Display translation decisions

    @Test
    func decidesDirectOnDVMBodies() {
        #expect(
            HDR10PlusProcessor.processingDecision(
                frame: Self.sampleFrame,
                target: .hdr10(understandsDVM: true)
            ) == .directWithDVM
        )
    }

    @Test
    func decidesStaticHDR10OnDVMIgnorantBody() {
        #expect(
            HDR10PlusProcessor.processingDecision(
                frame: Self.sampleFrame,
                target: .hdr10(understandsDVM: false)
            ) == .treatAsStaticHDR10
        )
    }

    @Test
    func decidesDoViConversionOnDolbyVisionDisplay() {
        #expect(
            HDR10PlusProcessor.processingDecision(
                frame: Self.sampleFrame,
                target: .dolbyVision
            ) == .processDVMToDolbyVision
        )
    }

    @Test
    func decidesDVMAwareToneMapOnSDRWhenBezierPresent() {
        #expect(
            HDR10PlusProcessor.processingDecision(
                frame: Self.sampleFrame,
                target: .sdr
            ) == .toneMapDVMAware
        )

        var clipped = Self.sampleFrame
        clipped.windows[0].bezierAnchors = [3]
        #expect(
            HDR10PlusProcessor.processingDecision(
                frame: clipped,
                target: .sdr
            ) == .treatAsStaticHDR10
        )
    }

    // MARK: - Tone-map parameter derivation

    @Test
    func derivesScenePeakAndKneeFromDVM() throws {
        let params = try #require(
            HDR10PlusProcessor.toneMapParameters(
                frame: Self.sampleFrame,
                displayPeakNits: 100
            )
        )
        // Fixture values use the spec's 1/10000ths-of-a-nit coding, so the
        // encoded 10_000 scene peak resolves to 1.0 nit and clamps to the
        // 100-nit output target.
        #expect(params.scenePeakNits == 100)
        #expect(params.displayPeakNits == 100)
        let knee = try #require(params.kneePoint)
        #expect(abs(knee - Double(153 + 306) / 2.0 / 1023.0) < 1e-9)
    }

    @Test
    func scenePeakTracksContentWhenWithinDisplayRange() throws {
        var frame = Self.sampleFrame
        // 10_000_000 × 0.0001 = 1000 nits of scene peak.
        frame.windows[0].maxSCL[2] = (19660, 10_000_000)
        let params = try #require(
            HDR10PlusProcessor.toneMapParameters(
                frame: frame,
                displayPeakNits: 100
            )
        )
        #expect(params.scenePeakNits == 1000)
    }

    @Test
    func returnsNilForEmptyScene() {
        let empty = HDR10PlusFrameMetadata(applicationVersion: 1, windows: [HDR10PlusWindowMetadata(mode: .basic)])
        #expect(HDR10PlusProcessor.toneMapParameters(frame: empty, displayPeakNits: 100) == nil)
    }
}
