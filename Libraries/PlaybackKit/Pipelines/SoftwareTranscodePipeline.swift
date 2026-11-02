import CoreVideo
import CoreKit
import Foundation

/// Tuning for the R4 software transcode pipeline.
public struct SoftwareTranscodeConfiguration: Sendable, Equatable {
    /// User preference that controls the worker budget (PB-24).
    public var qualityBias: PlaybackPreferences.QualityBias

    /// Explicit cap on decode workers. `nil` derives the cap from the bias.
    public var maximumWorkerCount: Int?

    /// Thermal state that triggers the resolution downgrade.
    public var downgradeThermalState: ThermalState

    /// Height used after a downgrade. 4K sources fall back to 1080p.
    public var downgradedHeight: Int

    /// Height considered "4K" for downgrade purposes.
    public var ultraHDHeight: Int

    public init(
        qualityBias: PlaybackPreferences.QualityBias = .balanced,
        maximumWorkerCount: Int? = nil,
        downgradeThermalState: ThermalState = .serious,
        downgradedHeight: Int = 1_080,
        ultraHDHeight: Int = 2_160
    ) {
        self.qualityBias = qualityBias
        self.maximumWorkerCount = maximumWorkerCount
        self.downgradeThermalState = downgradeThermalState
        self.downgradedHeight = max(1, downgradedHeight)
        self.ultraHDHeight = max(1, ultraHDHeight)
    }
}

/// Outcome of decoding one frame through R4.
public struct SoftwareTranscodeResult {
    /// Raw decoded (or downgraded) pixel buffer.
    public var pixelBuffer: CVPixelBuffer

    /// Target width after the thermal downgrade.
    public var width: Int

    /// Target height after the thermal downgrade.
    public var height: Int

    /// Decode workers allowed by the current quality bias.
    public var workerCount: Int

    /// Thermal pressure observed when the frame was decoded.
    public var thermalState: ThermalState

    /// Whether the 4K-to-1080p downgrade was applied.
    public var isThermallyDowngraded: Bool
}

/// R4 software transcode pipeline for codecs without hardware support
/// (AV1 on older Apple TVs, VP9, MPEG-2, VC-1).
///
/// The pipeline wraps a ``SoftwareVideoDecoding`` implementation, bounds the
/// worker pool so `balanced` never exceeds 60% of the machine's CPUs (PB-24),
/// and drops 4K output to 1080p once the ``ThermalMonitor`` reports
/// `.serious` or worse.
public struct SoftwareTranscodePipeline: Sendable {
    public var configuration: SoftwareTranscodeConfiguration
    public var decoder: any SoftwareVideoDecoding
    public var thermalMonitor: ThermalMonitor
    public var processorCount: Int

    public init(
        configuration: SoftwareTranscodeConfiguration = .init(),
        decoder: any SoftwareVideoDecoding = UnavailableSoftwareVideoDecoder(),
        thermalMonitor: ThermalMonitor = .shared,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.configuration = configuration
        self.decoder = decoder
        self.thermalMonitor = thermalMonitor
        self.processorCount = max(1, processorCount)
    }

    /// Decode workers allowed by the configured bias.
    public var workerCount: Int {
        let derived = Self.workerCount(
            qualityBias: configuration.qualityBias,
            processorCount: processorCount
        )
        if let cap = configuration.maximumWorkerCount {
            return min(derived, max(1, cap))
        }
        return derived
    }

    /// The most recent thermal state.
    public var thermalState: ThermalState {
        thermalMonitor.refresh()
        return thermalMonitor.currentState
    }

    /// Worker budget for a bias. `balanced` uses at most 60% of the CPUs.
    public static func workerCount(
        qualityBias: PlaybackPreferences.QualityBias,
        processorCount: Int
    ) -> Int {
        let fraction: Double
        switch qualityBias {
        case .balanced:
            fraction = 0.6
        case .lowestCPU:
            fraction = 0.25
        case .bestQuality:
            fraction = 1.0
        }
        let processors = max(1, processorCount)
        let raw = Double(processors) * fraction
        return max(1, min(processors, Int(raw.rounded(.down))))
    }

    /// Resolution after applying the thermal policy.
    ///
    /// Only sources at least 4K tall are downgraded; smaller content keeps its
    /// native size even under thermal pressure.
    public func targetHeight(
        sourceHeight: Int,
        thermalState: ThermalState? = nil
    ) -> Int {
        let state = thermalState ?? self.thermalState
        return Self.targetHeight(
            sourceHeight: sourceHeight,
            thermalState: state,
            configuration: configuration
        )
    }

    /// Pure resolution policy, exposed for tests and planning.
    public static func targetHeight(
        sourceHeight: Int,
        thermalState: ThermalState,
        configuration: SoftwareTranscodeConfiguration
    ) -> Int {
        guard sourceHeight >= configuration.ultraHDHeight,
              thermalState >= configuration.downgradeThermalState else {
            return sourceHeight
        }
        return min(sourceHeight, configuration.downgradedHeight)
    }

    /// Decodes one frame and applies the thermal resolution policy.
    public func decode(
        _ frame: SoftwareVideoFrame,
        codec: VideoCodec,
        sourceWidth: Int,
        sourceHeight: Int
    ) throws -> SoftwareTranscodeResult {
        let state = thermalState
        let height = Self.targetHeight(
            sourceHeight: sourceHeight,
            thermalState: state,
            configuration: configuration
        )
        let width: Int
        if height == sourceHeight {
            width = sourceWidth
        } else {
            let aspect = Double(sourceWidth) / Double(max(1, sourceHeight))
            width = max(1, Int((Double(height) * aspect).rounded()))
        }

        let pixelBuffer = try decoder.decode(
            frame,
            codec: codec,
            width: width,
            height: height
        )

        return SoftwareTranscodeResult(
            pixelBuffer: pixelBuffer,
            width: width,
            height: height,
            workerCount: workerCount,
            thermalState: state,
            isThermallyDowngraded: height != sourceHeight
        )
    }
}
