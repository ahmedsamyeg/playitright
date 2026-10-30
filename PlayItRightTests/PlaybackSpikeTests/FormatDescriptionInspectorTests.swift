import Testing
import CoreMedia
import CoreVideo

@Suite("FormatDescriptionInspector Tests")
struct FormatDescriptionInspectorTests {

    @Test("Synthetic SDR format description inspection")
    func testSDRFormatInspection() throws {
        let inspector = FormatDescriptionInspector()
        let desc = try FormatDescriptionInspector.createSyntheticFormat(
            codecType: kCMVideoCodecType_H264,
            width: 1920,
            height: 1080,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            bitDepth: 8
        )

        let info = inspector.inspect(formatDescription: desc)
        #expect(info.codecType == kCMVideoCodecType_H264)
        #expect(info.width == 1920)
        #expect(info.height == 1080)
        #expect(info.bitDepth == 8)
        #expect(info.colorClassification == .sdr)
        #expect(info.dolbyVisionProfile == nil)
    }

    @Test("Synthetic HDR10 format description inspection")
    func testHDR10FormatInspection() throws {
        let inspector = FormatDescriptionInspector()
        let desc = try FormatDescriptionInspector.createSyntheticFormat(
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            bitDepth: 10
        )

        let info = inspector.inspect(formatDescription: desc)
        #expect(info.codecType == kCMVideoCodecType_HEVC)
        #expect(info.width == 3840)
        #expect(info.height == 2160)
        #expect(info.bitDepth == 10)
        #expect(info.colorClassification == .hdr10)
    }

    @Test("Synthetic HLG format description inspection")
    func testHLGFormatInspection() throws {
        let inspector = FormatDescriptionInspector()
        let desc = try FormatDescriptionInspector.createSyntheticFormat(
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            bitDepth: 10
        )

        let info = inspector.inspect(formatDescription: desc)
        #expect(info.colorClassification == .hlg)
    }

    @Test("Synthetic Dolby Vision Profile 5 inspection")
    func testDolbyVisionProfile5Inspection() throws {
        let inspector = FormatDescriptionInspector()
        let desc = try FormatDescriptionInspector.createSyntheticFormat(
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            doviProfile: 5
        )

        let info = inspector.inspect(formatDescription: desc)
        #expect(info.dolbyVisionProfile == 5)
        #expect(info.colorClassification == .dolbyVision(profile: 5, compatibility: "Profile 5"))
    }

    @Test("Synthetic Dolby Vision Profile 8 inspection")
    func testDolbyVisionProfile8Inspection() throws {
        let inspector = FormatDescriptionInspector()
        let desc = try FormatDescriptionInspector.createSyntheticFormat(
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            doviProfile: 8
        )

        let info = inspector.inspect(formatDescription: desc)
        #expect(info.dolbyVisionProfile == 8)
        #expect(info.colorClassification == .dolbyVision(profile: 8, compatibility: "Profile 8"))
    }
}
