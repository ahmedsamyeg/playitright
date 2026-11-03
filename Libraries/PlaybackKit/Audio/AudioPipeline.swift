import Foundation

/// How the selected audio track is produced.
public enum AudioDecodeKind: String, Codable, Sendable, CaseIterable {
    case passthrough
    case hardware
    case software
}

/// One processed audio frame.
public struct AudioPipelineOutput: Sendable, Equatable {
    /// Interleaved PCM samples (passthrough frames are returned untouched).
    public var samples: [Float]

    /// Route in effect for this frame.
    public var route: AudioRoute

    /// Whether the frame was forwarded without decoding.
    public var isPassthrough: Bool

    /// Whether this frame triggered the decode + downmix fallback.
    public var didFallBack: Bool

    /// Route that failed when `didFallBack` is true.
    public var previousRoute: AudioRoute?
}

/// Applies an ``AudioPipelinePlan`` to decoded or passthrough audio
/// (PB-5, PB-11, PB-12, PB-14, doc 04 §6).
///
/// Downmix routes run through the ITU-R BS.775 matrix in
/// ``AudioDownmixMatrix``. A passthrough route is monitored for sustained
/// silence and falls back to software decode + downmix after two seconds.
public final class AudioPipeline: @unchecked Sendable {
    /// Extra center-channel gain used by the stereo preset.
    public static let stereoDialogEnhancementDB = 1.5

    /// The sink this pipeline renders to.
    public let sink: AudioCapabilities

    /// Detects a silently ignored passthrough stream.
    public let passthroughMonitor: PassthroughMonitor

    private let lock = NSLock()
    private var storedPlan: AudioPipelinePlan
    private var storedMatrix: AudioDownmixMatrix?

    public init(
        plan: AudioPipelinePlan,
        sink: AudioCapabilities,
        passthroughMonitor: PassthroughMonitor = PassthroughMonitor()
    ) {
        self.sink = sink
        self.passthroughMonitor = passthroughMonitor
        self.storedPlan = plan
        self.storedMatrix = Self.matrix(
            for: plan.route,
            inputChannels: plan.channels
        )
    }

    /// The current plan. Its route changes after a passthrough fallback.
    public var plan: AudioPipelinePlan {
        lock.lock()
        defer { lock.unlock() }
        return storedPlan
    }

    /// The downmix matrix in effect, when the route downmixes.
    public var matrix: AudioDownmixMatrix? {
        lock.lock()
        defer { lock.unlock() }
        return storedMatrix
    }

    /// Decode path implied by the current route.
    public var decodeKind: AudioDecodeKind {
        switch plan.route {
        case .passthrough:
            return .passthrough
        case .nativeDecode:
            return .hardware
        case .softwareDecode, .downmixToStereo, .downmixTo51:
            return .software
        }
    }

    /// Processes one frame of interleaved PCM.
    ///
    /// Passthrough frames are returned byte-for-byte. Once the monitor has
    /// seen two seconds of silence, the route is replaced with software decode
    /// and the frame is downmixed to the sink's channel limit.
    public func process(
        _ samples: [Float],
        at timestamp: TimeInterval
    ) -> AudioPipelineOutput {
        lock.lock()
        defer { lock.unlock() }

        guard storedPlan.route == .passthrough else {
            return output(samples, route: storedPlan.route)
        }

        passthroughMonitor.record(samples: samples, at: timestamp)
        guard passthroughMonitor.shouldFallBack(at: timestamp) else {
            return output(samples, route: .passthrough)
        }

        let previous = storedPlan.route
        let fallback = Self.fallbackRoute(
            inputChannels: storedPlan.channels,
            sink: sink
        )
        storedPlan.route = fallback
        storedPlan.outputCodec = "pcm"
        storedPlan.outputChannels = Self.outputChannels(
            for: fallback,
            inputChannels: storedPlan.channels,
            sink: sink
        )
        storedPlan.isAtmos = false
        storedMatrix = Self.matrix(
            for: fallback,
            inputChannels: storedPlan.channels
        )

        return AudioPipelineOutput(
            samples: storedMatrix?.mix(samples) ?? samples,
            route: fallback,
            isPassthrough: false,
            didFallBack: true,
            previousRoute: previous
        )
    }

    /// Matrix used for a route, or `nil` when no downmix is needed.
    public static func matrix(
        for route: AudioRoute,
        inputChannels: Int
    ) -> AudioDownmixMatrix? {
        let input = AudioChannelLayout.standard(
            channelCount: max(1, inputChannels)
        )
        switch route {
        case .downmixToStereo:
            return .ituBS775(
                from: input,
                to: .stereo,
                dialogEnhancementDB: stereoDialogEnhancementDB
            )
        case .downmixTo51:
            return .ituBS775(from: input, to: .surround51)
        case .passthrough, .nativeDecode, .softwareDecode:
            return nil
        }
    }

    /// Route used after passthrough fails.
    public static func fallbackRoute(
        inputChannels: Int,
        sink: AudioCapabilities
    ) -> AudioRoute {
        guard inputChannels > sink.maxChannels else {
            return .softwareDecode
        }
        return sink.maxChannels <= 2 ? .downmixToStereo : .downmixTo51
    }

    private static func outputChannels(
        for route: AudioRoute,
        inputChannels: Int,
        sink: AudioCapabilities
    ) -> Int {
        switch route {
        case .downmixToStereo:
            return 2
        case .downmixTo51:
            return min(6, max(2, sink.maxChannels))
        case .passthrough, .nativeDecode, .softwareDecode:
            return inputChannels
        }
    }

    private func output(
        _ samples: [Float],
        route: AudioRoute
    ) -> AudioPipelineOutput {
        AudioPipelineOutput(
            samples: storedMatrix?.mix(samples) ?? samples,
            route: route,
            isPassthrough: route == .passthrough,
            didFallBack: false,
            previousRoute: nil
        )
    }
}
