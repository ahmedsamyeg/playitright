import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Represents the analyzed color space classification of a video stream.
public enum ColorClassification: Equatable, Sendable {
    case sdr
    case hdr10
    case hdr10Plus
    case hlg
    case dolbyVision(profile: Int, compatibility: String?)
    case unknown
}

/// Detailed colorimetry and format characteristics extracted from a `CMFormatDescription`.
public struct VideoFormatInfo: Equatable, Sendable {
    public let codecType: CMVideoCodecType
    public let width: Int32
    public let height: Int32
    public let bitDepth: Int
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let matrix: String?
    public let isFullRange: Bool
    public let colorClassification: ColorClassification
    public let dolbyVisionProfile: Int?
    public let dolbyVisionCompatibility: String?

    public init(
        codecType: CMVideoCodecType,
        width: Int32,
        height: Int32,
        bitDepth: Int,
        colorPrimaries: String?,
        transferFunction: String?,
        matrix: String?,
        isFullRange: Bool,
        colorClassification: ColorClassification,
        dolbyVisionProfile: Int? = nil,
        dolbyVisionCompatibility: String? = nil
    ) {
        self.codecType = codecType
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.matrix = matrix
        self.isFullRange = isFullRange
        self.colorClassification = colorClassification
        self.dolbyVisionProfile = dolbyVisionProfile
        self.dolbyVisionCompatibility = dolbyVisionCompatibility
    }
}

/// Inspects and extracts structured metadata from `CMVideoFormatDescription` instances (ARCH-1, PB-3, PB-4).
public final class FormatDescriptionInspector: Sendable {

    public init() {}

    /// Inspects a given `CMVideoFormatDescription` and returns a structured `VideoFormatInfo`.
    public func inspect(formatDescription: CMVideoFormatDescription) -> VideoFormatInfo {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)

        // Read extensions dictionary
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any] ?? [:]

        let primaries = extensions[kCVImageBufferColorPrimariesKey as String] as? String
        let transfer = extensions[kCVImageBufferTransferFunctionKey as String] as? String
        let matrix = extensions[kCVImageBufferYCbCrMatrixKey as String] as? String
        let isFullRange = (extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool) ?? false

        // Determine bit depth
        let bitDepth: Int
        if let depthNum = extensions["BitsPerComponent"] as? Int {
            bitDepth = depthNum
        } else if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) ||
                  transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
            bitDepth = 10
        } else {
            bitDepth = 8
        }

        // Check for Dolby Vision sample extension atoms
        var doviProfile: Int? = nil
        var doviCompat: String? = nil

        if let sampleAtoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] {
            if let dvcC = sampleAtoms["dvcC"] as? Data, dvcC.count >= 4 {
                // dv_profile is bits 7..1 of byte 2
                let profile = Int((dvcC[2] >> 1) & 0x7F)
                doviProfile = profile
                doviCompat = "Profile \(profile)"
            } else if let dv8C = sampleAtoms["dv8C"] as? Data, dv8C.count >= 4 {
                let profile = Int((dv8C[2] >> 1) & 0x7F)
                doviProfile = profile
                doviCompat = "Profile \(profile)"
            }
        }

        // Color classification
        let classification: ColorClassification
        if let profile = doviProfile {
            classification = .dolbyVision(profile: profile, compatibility: doviCompat)
        } else if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
            classification = .hdr10
        } else if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
            classification = .hlg
        } else if transfer == (kCVImageBufferTransferFunction_ITU_R_709_2 as String) ||
                  transfer == (kCVImageBufferTransferFunction_UseGamma as String) ||
                  transfer == nil {
            classification = .sdr
        } else {
            classification = .unknown
        }

        return VideoFormatInfo(
            codecType: mediaSubType,
            width: dimensions.width,
            height: dimensions.height,
            bitDepth: bitDepth,
            colorPrimaries: primaries,
            transferFunction: transfer,
            matrix: matrix,
            isFullRange: isFullRange,
            colorClassification: classification,
            dolbyVisionProfile: doviProfile,
            dolbyVisionCompatibility: doviCompat
        )
    }

    /// Helper to synthesize a `CMVideoFormatDescription` for test assertions without requiring media files.
    public static func createSyntheticFormat(
        codecType: CMVideoCodecType = kCMVideoCodecType_HEVC,
        width: Int32 = 3840,
        height: Int32 = 2160,
        primaries: CFString = kCVImageBufferColorPrimaries_ITU_R_2020,
        transfer: CFString = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
        matrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_2020,
        bitDepth: Int = 10,
        doviProfile: Int? = nil
    ) throws -> CMVideoFormatDescription {
        var extensions: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: primaries,
            kCVImageBufferTransferFunctionKey: transfer,
            kCVImageBufferYCbCrMatrixKey: matrix,
            "BitsPerComponent" as CFString: bitDepth
        ]

        if let profile = doviProfile {
            // Synthesize minimal dvcC/dv8C atom
            let dvAtom = Data([0x01, 0x00, UInt8((profile & 0x7F) << 1), 0x00])
            let sampleAtoms: [CFString: Any] = [
                (profile == 8 ? "dv8C" : "dvcC") as CFString: dvAtom
            ]
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as CFString] = sampleAtoms
        }

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let desc = formatDescription else {
            throw NSError(domain: "FormatDescriptionInspector", code: Int(status), userInfo: nil)
        }
        return desc
    }
}
