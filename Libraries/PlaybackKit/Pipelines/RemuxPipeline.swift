import Foundation

/// A packet emitted by a container demuxer, in its track's timescale.
public struct RemuxPacket: Sendable, Equatable {
    public var trackID: UInt32
    public var sample: FMP4Sample

    public init(trackID: UInt32, sample: FMP4Sample) {
        self.trackID = trackID
        self.sample = sample
    }
}

/// One chunk of the remux output. The first item is always the fMP4
/// initialization segment; each later item is a `moof` + `mdat` fragment.
public struct RemuxOutput: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case initialization
        case fragment
    }

    public var kind: Kind
    public var trackID: UInt32?
    public var sequenceNumber: UInt32?
    public var data: Data

    public init(
        kind: Kind,
        trackID: UInt32? = nil,
        sequenceNumber: UInt32? = nil,
        data: Data
    ) {
        self.kind = kind
        self.trackID = trackID
        self.sequenceNumber = sequenceNumber
        self.data = data
    }
}

/// The demuxing seam for R2. FFmpeg supplies packets through this protocol;
/// tests and diagnostics can replay recorded packets without the binary
/// (PB-3, doc 04 §4.2).
public protocol RemuxDemuxing: Sendable {
    func tracks(
        url: URL,
        container: ContainerFormat
    ) async throws -> [FMP4Track]

    func packets(
        url: URL,
        container: ContainerFormat
    ) -> AsyncThrowingStream<RemuxPacket, Error>
}

/// Placeholder used when the FFmpeg XCFramework is not linked.
public struct UnavailableRemuxDemuxer: RemuxDemuxing {
    public init() {}

    public func tracks(
        url: URL,
        container: ContainerFormat
    ) async throws -> [FMP4Track] {
        throw StreamProbeError.ffmpegUnavailable
    }

    public func packets(
        url: URL,
        container: ContainerFormat
    ) -> AsyncThrowingStream<RemuxPacket, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: StreamProbeError.ffmpegUnavailable
            )
        }
    }
}

/// R2 remux pipeline: demux a non-Apple container and repackage the original
/// compressed packets into fragmented MP4 for `AVPlayer`.
///
/// No video or audio sample is decoded or re-encoded. Dolby Vision RPU NAL
/// units can be stripped when the sink only supports HDR10 (PB-G4).
public struct RemuxPipeline: Sendable {
    public var demuxer: any RemuxDemuxing
    public var stripDolbyVisionRPU: Bool
    public var maxSamplesPerFragment: Int

    public init(
        demuxer: any RemuxDemuxing = UnavailableRemuxDemuxer(),
        stripDolbyVisionRPU: Bool = false,
        maxSamplesPerFragment: Int = 30
    ) {
        self.demuxer = demuxer
        self.stripDolbyVisionRPU = stripDolbyVisionRPU
        self.maxSamplesPerFragment = max(1, maxSamplesPerFragment)
    }

    /// Streams the initialization segment followed by media fragments.
    public func remux(
        url: URL,
        container: ContainerFormat
    ) -> AsyncThrowingStream<RemuxOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tracks = try await demuxer.tracks(
                        url: url,
                        container: container
                    )
                    let packager = FMP4Packager(
                        tracks: tracks,
                        stripDolbyVisionRPU: stripDolbyVisionRPU
                    )
                    continuation.yield(
                        RemuxOutput(
                            kind: .initialization,
                            data: packager.initializationSegment()
                        )
                    )

                    var sequenceNumber: UInt32 = 1
                    var currentTrack: UInt32?
                    var samples: [FMP4Sample] = []

                    func flush() throws {
                        guard let trackID = currentTrack,
                              !samples.isEmpty else {
                            samples.removeAll(keepingCapacity: true)
                            return
                        }
                        let fragment = try packager.fragment(
                            trackID: trackID,
                            samples: samples,
                            sequenceNumber: sequenceNumber
                        )
                        continuation.yield(
                            RemuxOutput(
                                kind: .fragment,
                                trackID: trackID,
                                sequenceNumber: sequenceNumber,
                                data: fragment
                            )
                        )
                        sequenceNumber += 1
                        samples.removeAll(keepingCapacity: true)
                    }

                    for try await packet in demuxer.packets(
                        url: url,
                        container: container
                    ) {
                        if currentTrack != packet.trackID {
                            try flush()
                            currentTrack = packet.trackID
                        }
                        samples.append(packet.sample)
                        if samples.count >= maxSamplesPerFragment {
                            try flush()
                        }
                    }
                    try flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
