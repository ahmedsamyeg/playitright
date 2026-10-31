import Foundation

/// Audio output capabilities for the connected HDMI sink.
///
/// tvOS does not expose a rich route-introspection API, so the sink's
/// passthrough support is modelled as a declaration that can come from the
/// receiver profile or a developer override. The probe keeps that declaration
/// in one place for the audio planner.
public struct AudioOutputCapabilities: Codable, Sendable, Equatable {
    public let passthroughCodecs: Set<AudioCodec>
    public let decodedCodecs: Set<AudioCodec>

    public init(passthroughCodecs: Set<AudioCodec>, decodedCodecs: Set<AudioCodec>) {
        self.passthroughCodecs = passthroughCodecs
        self.decodedCodecs = decodedCodecs
    }

    public func canPassthrough(_ codec: AudioCodec) -> Bool {
        passthroughCodecs.contains(codec)
    }

    public func canDecode(_ codec: AudioCodec) -> Bool {
        decodedCodecs.contains(codec)
    }

    /// The full per-codec capability list used by the planner.
    public func capabilities() -> [AudioCodecCapability] {
        AudioCodec.allCases.map { codec in
            AudioCodecCapability(
                codec: codec,
                hardwareDecode: decodedCodecs.contains(codec),
                softwareDecode: decodedCodecs.contains(codec),
                passthrough: passthroughCodecs.contains(codec)
            )
        }
    }
}

/// Source of the sink's declared audio capabilities.
public protocol AudioOutputProbing: Sendable {
    func capabilities() -> AudioOutputCapabilities
}

/// Default sink declaration: the receiver accepts every common format.
///
/// The audio planner still validates against the device matrix; this type only
/// captures what the user's HDMI chain reported.
public struct DeclaredAudioOutputProbe: AudioOutputProbing {
    public let declaration: AudioOutputCapabilities

    public init(
        passthroughCodecs: Set<AudioCodec> = Set(AudioCodec.allCases),
        decodedCodecs: Set<AudioCodec> = Set(AudioCodec.allCases)
    ) {
        self.declaration = AudioOutputCapabilities(
            passthroughCodecs: passthroughCodecs,
            decodedCodecs: decodedCodecs
        )
    }

    public func capabilities() -> AudioOutputCapabilities {
        declaration
    }
}

/// Resolves and exposes the current audio output capabilities.
public final class AudioOutputProbe: Sendable {
    private let prober: any AudioOutputProbing

    public init(prober: any AudioOutputProbing = DeclaredAudioOutputProbe()) {
        self.prober = prober
    }

    public func capabilities() -> AudioOutputCapabilities {
        prober.capabilities()
    }

    public func canPassthrough(_ codec: AudioCodec) -> Bool {
        prober.capabilities().canPassthrough(codec)
    }
}
