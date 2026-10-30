import Foundation
import CoreMedia

/// Capabilities of the connected physical display or TV (PB-4, PB-16).
public struct DisplayProfile: Equatable, Sendable {
    public var supportsDolbyVisionProfile5: Bool
    public var supportsDolbyVisionProfile8: Bool
    public var supportsHDR10: Bool
    public var supportsHLG: Bool
    public var maxDisplayNits: Double
    public var nativeResolution: (width: Int, height: Int)

    public init(
        supportsDolbyVisionProfile5: Bool = false,
        supportsDolbyVisionProfile8: Bool = false,
        supportsHDR10: Bool = false,
        supportsHLG: Bool = false,
        maxDisplayNits: Double = 100.0,
        nativeResolution: (width: Int, height: Int) = (3840, 2160)
    ) {
        self.supportsDolbyVisionProfile5 = supportsDolbyVisionProfile5
        self.supportsDolbyVisionProfile8 = supportsDolbyVisionProfile8
        self.supportsHDR10 = supportsHDR10
        self.supportsHLG = supportsHLG
        self.maxDisplayNits = maxDisplayNits
        self.nativeResolution = nativeResolution
    }

    public static func == (lhs: DisplayProfile, rhs: DisplayProfile) -> Bool {
        return lhs.supportsDolbyVisionProfile5 == rhs.supportsDolbyVisionProfile5 &&
               lhs.supportsDolbyVisionProfile8 == rhs.supportsDolbyVisionProfile8 &&
               lhs.supportsHDR10 == rhs.supportsHDR10 &&
               lhs.supportsHLG == rhs.supportsHLG &&
               lhs.maxDisplayNits == rhs.maxDisplayNits &&
               lhs.nativeResolution.width == rhs.nativeResolution.width &&
               lhs.nativeResolution.height == rhs.nativeResolution.height
    }

    /// Standard SDR television profile (1080p or 4K SDR).
    public static let standardSDR = DisplayProfile(
        supportsDolbyVisionProfile5: false,
        supportsDolbyVisionProfile8: false,
        supportsHDR10: false,
        supportsHLG: false,
        maxDisplayNits: 100.0
    )

    /// Standard HDR10 television (supports HDR10 and HLG, but not Dolby Vision).
    public static let standardHDR10 = DisplayProfile(
        supportsDolbyVisionProfile5: false,
        supportsDolbyVisionProfile8: false,
        supportsHDR10: true,
        supportsHLG: true,
        maxDisplayNits: 1000.0
    )

    /// Full Dolby Vision television (supports DoVi Profile 5, 8, HDR10, HLG).
    public static let fullDolbyVision = DisplayProfile(
        supportsDolbyVisionProfile5: true,
        supportsDolbyVisionProfile8: true,
        supportsHDR10: true,
        supportsHLG: true,
        maxDisplayNits: 1000.0
    )
}

/// Resolved video color routing action (doc 04 §7, PB-16, PB-17).
public enum ColorPipelineAction: Equatable, Sendable {
    /// Present stream directly to display without color alteration.
    case directPassthrough
    /// Strip Dolby Vision RPU metadata and present base layer as standard HDR10.
    case stripRPUToHDR10
    /// Delegate tone mapping to Apple's system compositor (AVPlayer native).
    case systemToneMapToSDR
    /// Explicit shader / CoreImage / zscale tone mapping (used in precise mode or software transcode).
    case explicitToneMapToSDR(targetNits: Double)
    /// Convert HLG to PQ/HDR10.
    case convertHLGToHDR10
}

/// Resolves color pipeline actions by matching source video characteristics against display capabilities.
public final class DisplayCapabilityDetector: Sendable {

    public init() {}

    /// Determines the correct color pipeline action for a given video format and display profile.
    public func resolveColorAction(
        format: VideoFormatInfo,
        display: DisplayProfile,
        preferPreciseToneMap: Bool = false
    ) -> ColorPipelineAction {
        switch format.colorClassification {
        case .sdr:
            return .directPassthrough

        case .dolbyVision(let profile, _):
            if profile == 5 {
                if display.supportsDolbyVisionProfile5 {
                    return .directPassthrough
                } else if display.supportsHDR10 {
                    // Profile 5 has proprietary IPTPQc2 color space; without DoVi display, needs conversion or system tone-map
                    return preferPreciseToneMap ? .explicitToneMapToSDR(targetNits: display.maxDisplayNits) : .systemToneMapToSDR
                } else {
                    return preferPreciseToneMap ? .explicitToneMapToSDR(targetNits: display.maxDisplayNits) : .systemToneMapToSDR
                }
            } else if profile == 8 || profile == 7 {
                if display.supportsDolbyVisionProfile8 {
                    return .directPassthrough
                } else if display.supportsHDR10 {
                    // Profile 8 has standard HEVC HDR10 base layer: strip RPU and play as HDR10! (PB-G4)
                    return .stripRPUToHDR10
                } else {
                    // SDR Display: system tone-map or explicit tone-map
                    return preferPreciseToneMap ? .explicitToneMapToSDR(targetNits: display.maxDisplayNits) : .systemToneMapToSDR
                }
            } else {
                return preferPreciseToneMap ? .explicitToneMapToSDR(targetNits: display.maxDisplayNits) : .systemToneMapToSDR
            }

        case .hdr10, .hdr10Plus:
            if display.supportsHDR10 {
                return .directPassthrough
            } else {
                return preferPreciseToneMap ? .explicitToneMapToSDR(targetNits: display.maxDisplayNits) : .systemToneMapToSDR
            }

        case .hlg:
            if display.supportsHLG {
                return .directPassthrough
            } else if display.supportsHDR10 {
                return .convertHLGToHDR10
            } else {
                return preferPreciseToneMap ? .explicitToneMapToSDR(targetNits: display.maxDisplayNits) : .systemToneMapToSDR
            }

        case .unknown:
            return .directPassthrough
        }
    }
}
