import Testing
import CoreMedia
import CoreVideo
@testable import PlaybackSpike

@Suite("DisplayCapabilityDetector Tests")
struct DisplayCapabilityDetectorTests {

    let detector = DisplayCapabilityDetector()

    @Test("SDR content on any display always results in direct passthrough")
    func testSDROnAnyDisplay() {
        let sdrFormat = VideoFormatInfo(
            codecType: kCMVideoCodecType_H264,
            width: 1920,
            height: 1080,
            bitDepth: 8,
            colorPrimaries: nil,
            transferFunction: nil,
            matrix: nil,
            isFullRange: false,
            colorClassification: .sdr
        )

        #expect(detector.resolveColorAction(format: sdrFormat, display: .standardSDR) == .directPassthrough)
        #expect(detector.resolveColorAction(format: sdrFormat, display: .standardHDR10) == .directPassthrough)
        #expect(detector.resolveColorAction(format: sdrFormat, display: .fullDolbyVision) == .directPassthrough)
    }

    @Test("HDR10 on HDR10 or Dolby Vision display results in direct passthrough")
    func testHDR10OnHDRDisplay() {
        let hdrFormat = VideoFormatInfo(
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            bitDepth: 10,
            colorPrimaries: nil,
            transferFunction: nil,
            matrix: nil,
            isFullRange: false,
            colorClassification: .hdr10
        )

        #expect(detector.resolveColorAction(format: hdrFormat, display: .standardHDR10) == .directPassthrough)
        #expect(detector.resolveColorAction(format: hdrFormat, display: .fullDolbyVision) == .directPassthrough)
    }

    @Test("HDR10 on SDR display results in tone map")
    func testHDR10OnSDRDisplay() {
        let hdrFormat = VideoFormatInfo(
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            bitDepth: 10,
            colorPrimaries: nil,
            transferFunction: nil,
            matrix: nil,
            isFullRange: false,
            colorClassification: .hdr10
        )

        #expect(detector.resolveColorAction(format: hdrFormat, display: .standardSDR, preferPreciseToneMap: false) == .systemToneMapToSDR)
        #expect(detector.resolveColorAction(format: hdrFormat, display: .standardSDR, preferPreciseToneMap: true) == .explicitToneMapToSDR(targetNits: 100.0))
    }

    @Test("Dolby Vision Profile 8 on HDR10 display strips RPU to HDR10 (PB-G4)")
    func testDoViProfile8OnHDR10Display() {
        let dovi8Format = VideoFormatInfo(
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            bitDepth: 10,
            colorPrimaries: nil,
            transferFunction: nil,
            matrix: nil,
            isFullRange: false,
            colorClassification: .dolbyVision(profile: 8, compatibility: "Profile 8"),
            dolbyVisionProfile: 8
        )

        // On HDR10 display (no DoVi license / sink support), strip RPU and play base HEVC HDR10!
        #expect(detector.resolveColorAction(format: dovi8Format, display: .standardHDR10) == .stripRPUToHDR10)

        // On Full DoVi display, passthrough directly
        #expect(detector.resolveColorAction(format: dovi8Format, display: .fullDolbyVision) == .directPassthrough)

        // On SDR display, tone map
        #expect(detector.resolveColorAction(format: dovi8Format, display: .standardSDR, preferPreciseToneMap: false) == .systemToneMapToSDR)
        #expect(detector.resolveColorAction(format: dovi8Format, display: .standardSDR, preferPreciseToneMap: true) == .explicitToneMapToSDR(targetNits: 100.0))
    }

    @Test("Dolby Vision Profile 5 on DoVi display direct passthrough")
    func testDoViProfile5() {
        let dovi5Format = VideoFormatInfo(
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            bitDepth: 10,
            colorPrimaries: nil,
            transferFunction: nil,
            matrix: nil,
            isFullRange: false,
            colorClassification: .dolbyVision(profile: 5, compatibility: "Profile 5"),
            dolbyVisionProfile: 5
        )

        #expect(detector.resolveColorAction(format: dovi5Format, display: .fullDolbyVision) == .directPassthrough)
        #expect(detector.resolveColorAction(format: dovi5Format, display: .standardSDR) == .systemToneMapToSDR)
    }
}
