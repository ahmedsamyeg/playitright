import Foundation
import Synchronization
import Testing
@testable import PlaybackKit

// MARK: - Mock transport

private final class MockCastTransport: GoogleCastTransport, @unchecked Sendable {
    private struct State {
        var devices: [GoogleCastDevice]
        var loads: [GoogleCastLoadRequest] = []
        var stops: [GoogleCastDevice] = []
        var discoveryError: GoogleCastError?
        var loadError: GoogleCastError?
    }

    private let state: Mutex<State>

    init(
        devices: [GoogleCastDevice] = [],
        discoveryError: GoogleCastError? = nil,
        loadError: GoogleCastError? = nil
    ) {
        self.state = Mutex(
            State(
                devices: devices,
                discoveryError: discoveryError,
                loadError: loadError
            )
        )
    }

    func discoverDevices() async throws -> [GoogleCastDevice] {
        try state.withLock { state in
            if let discoveryError = state.discoveryError {
                throw discoveryError
            }
            return state.devices
        }
    }

    func load(
        _ request: GoogleCastLoadRequest,
        on device: GoogleCastDevice
    ) async throws {
        try state.withLock { state in
            if let loadError = state.loadError {
                throw loadError
            }
            state.loads.append(request)
        }
    }

    func stop(on device: GoogleCastDevice) async throws {
        state.withLock { state in
            state.stops.append(device)
        }
    }

    var recordedLoads: [GoogleCastLoadRequest] {
        state.withLock { $0.loads }
    }

    var recordedStops: [GoogleCastDevice] {
        state.withLock { $0.stops }
    }
}

// MARK: - Fixtures

private let castURL = URL(string: "https://media.example.com/movies/film.mp4")!

private func videoGraph(
    container: ContainerFormat = .mp4,
    codec: VideoCodec = .h264,
    hdr: HDRFormat = .sdr,
    audioCodec: AudioCodec = .aac,
    channels: Int = 2,
    duration: TimeInterval? = 5_400
) -> MediaGraph {
    MediaGraph(
        container: container,
        demuxer: container.isAVFoundationNative ? .avFoundation : .ffmpeg,
        duration: duration,
        videoTracks: [
            VideoTrackInfo(
                index: 0,
                codec: codec,
                width: 3_840,
                height: 2_160,
                hdrFormat: hdr
            )
        ],
        audioTracks: [
            AudioTrackInfo(
                index: 1,
                codec: audioCodec,
                channels: channels,
                sampleRate: 48_000,
                isDefault: true
            )
        ]
    )
}

private func audioGraph(
    container: ContainerFormat = .ogg,
    codec: AudioCodec = .flac,
    channels: Int = 2
) -> MediaGraph {
    MediaGraph(
        container: container,
        demuxer: .ffmpeg,
        duration: 240,
        audioTracks: [
            AudioTrackInfo(
                index: 0,
                codec: codec,
                channels: channels,
                sampleRate: 48_000,
                isDefault: true
            )
        ]
    )
}

private func chromecast(
    name: String = "Living Room",
    reachable: Bool = true
) -> GoogleCastDevice {
    GoogleCastDevice(
        id: "cast-1",
        name: name,
        kind: .chromecast,
        isReachable: reachable
    )
}

private func chromecastUltra(
    name: String = "Theater"
) -> GoogleCastDevice {
    GoogleCastDevice(
        id: "cast-ultra",
        name: name,
        kind: .chromecastUltra
    )
}

private func chromecastAudio(
    name: String = "Kitchen Speaker"
) -> GoogleCastDevice {
    GoogleCastDevice(
        id: "cast-audio",
        name: name,
        kind: .chromecastAudio
    )
}

@MainActor
private func makeController(
    pro: Bool = true,
    transport: MockCastTransport = MockCastTransport()
) -> GoogleCastController {
    GoogleCastController(
        entitlement: pro ? StaticProEntitlement.pro : StaticProEntitlement.free,
        transport: transport
    )
}

// MARK: - Tests

@Suite("GoogleCastController Tests")
struct GoogleCastControllerTests {
    @Test("Supported video produces a load request with the right media type")
    @MainActor
    func supportedVideoNegotiation() {
        let controller = makeController()
        let device = chromecast()

        let decision = controller.decide(
            graph: videoGraph(),
            access: .publiclyReachable(castURL),
            device: device,
            title: "The Movie",
            subtitle: "Season 1 · Episode 2",
            startPosition: 120
        )

        let request = decision.request
        #expect(request?.deviceID == device.id)
        #expect(request?.media.url == castURL)
        #expect(request?.media.contentType == "video/mp4")
        #expect(request?.media.title == "The Movie")
        #expect(request?.media.subtitle == "Season 1 · Episode 2")
        #expect(request?.media.duration == 5_400)
        #expect(request?.media.startPosition == 120)
        #expect(request?.media.isAudioOnly == false)
        #expect(!decision.isDeclined)
        #expect(controller.lastDecision == decision)
    }

    @Test("A supported cast reaches the receiver through the transport")
    @MainActor
    func successfulCastSendsLoad() async throws {
        let transport = MockCastTransport()
        let controller = makeController(transport: transport)
        let device = chromecast()

        let decision = try await controller.cast(
            graph: videoGraph(),
            access: .publiclyReachable(castURL),
            device: device,
            title: "The Movie"
        )

        #expect(decision.request != nil)
        #expect(transport.recordedLoads.count == 1)
        #expect(transport.recordedLoads.first?.media.url == castURL)
        #expect(controller.isCasting)
        #expect(controller.activeDevice == device)

        try await controller.stopCasting()
        #expect(transport.recordedStops == [device])
        #expect(!controller.isCasting)
        #expect(controller.activeDevice == nil)
    }

    @Test("Audio-only media casts to a Chromecast Audio with an audio type")
    @MainActor
    func audioOnlyCasting() {
        let controller = makeController()
        let device = chromecastAudio()

        let decision = controller.decide(
            graph: audioGraph(),
            access: .publiclyReachable(castURL),
            device: device,
            title: "Album"
        )

        let media = decision.request?.media
        #expect(media?.isAudioOnly == true)
        #expect(media?.contentType == "audio/ogg")
    }

    @Test("Audio-only media is declined on a video-only receiver")
    @MainActor
    func audioOnlyDeclinedOnVideoReceiver() {
        let controller = makeController()

        let decision = controller.decide(
            graph: audioGraph(),
            access: .publiclyReachable(castURL),
            device: chromecast(),
            title: "Album"
        )

        #expect(decision == .declined(.audioOnlyUnsupported("Living Room")))
    }

    @Test("An unsupported container is declined with a plain explanation")
    @MainActor
    func unsupportedContainer() {
        let controller = makeController()

        let decision = controller.decide(
            graph: videoGraph(container: .mkv, codec: .h264),
            access: .publiclyReachable(castURL),
            device: chromecast(),
            title: "The Movie"
        )

        #expect(
            decision == .declined(
                .unsupportedContainer(.mkv, device: "Living Room")
            )
        )
        #expect(decision.explanation?.contains("MKV") == true)
    }

    @Test("An unsupported video codec is declined")
    @MainActor
    func unsupportedVideoCodec() {
        let controller = makeController()

        let decision = controller.decide(
            graph: videoGraph(codec: .mpeg2),
            access: .publiclyReachable(castURL),
            device: chromecast(),
            title: "The Movie"
        )

        #expect(
            decision == .declined(
                .unsupportedVideoCodec(.mpeg2, device: "Living Room")
            )
        )
        #expect(decision.explanation?.contains("MPEG2") == true)
    }

    @Test("An unsupported audio codec is declined")
    @MainActor
    func unsupportedAudioCodec() {
        let controller = makeController()

        let decision = controller.decide(
            graph: videoGraph(audioCodec: .dts),
            access: .publiclyReachable(castURL),
            device: chromecast(),
            title: "The Movie"
        )

        #expect(
            decision == .declined(
                .unsupportedAudioCodec(.dts, device: "Living Room")
            )
        )
    }

    @Test("HDR and Dolby Vision are negotiated per receiver")
    @MainActor
    func hdrNegotiation() {
        let controller = makeController()

        let hdrOnHD = controller.decide(
            graph: videoGraph(hdr: .hdr10),
            access: .publiclyReachable(castURL),
            device: chromecast(),
            title: "The Movie"
        )
        #expect(
            hdrOnHD == .declined(
                .unsupportedHDR(.hdr10, device: "Living Room")
            )
        )

        let hdrOnUltra = controller.decide(
            graph: videoGraph(hdr: .hdr10),
            access: .publiclyReachable(castURL),
            device: chromecastUltra(),
            title: "The Movie"
        )
        #expect(hdrOnUltra.request != nil)

        let doviOnUltra = controller.decide(
            graph: videoGraph(hdr: .dolbyVision8),
            access: .publiclyReachable(castURL),
            device: chromecastUltra(),
            title: "The Movie"
        )
        #expect(doviOnUltra.request != nil)

        let doviOnHD = controller.decide(
            graph: videoGraph(hdr: .dolbyVision8),
            access: .publiclyReachable(castURL),
            device: chromecast(),
            title: "The Movie"
        )
        #expect(
            doviOnHD == .declined(
                .unsupportedHDR(.dolbyVision8, device: "Living Room")
            )
        )
    }

    @Test("Channel counts beyond the receiver limit are declined")
    @MainActor
    func channelNegotiation() {
        let controller = makeController()

        let stereoOnly = controller.decide(
            graph: videoGraph(channels: 6),
            access: .publiclyReachable(castURL),
            device: chromecast(),
            title: "The Movie"
        )
        #expect(
            stereoOnly == .declined(
                .unsupportedChannelCount(
                    6,
                    maximum: 2,
                    device: "Living Room"
                )
            )
        )

        let surround = controller.decide(
            graph: videoGraph(channels: 6),
            access: .publiclyReachable(castURL),
            device: chromecastUltra(),
            title: "The Movie"
        )
        #expect(surround.request != nil)
    }

    @Test("Private shares are declined with a clear explanation")
    @MainActor
    func privateShareDeclined() {
        let controller = makeController()
        let transport = MockCastTransport()
        let controllerWithTransport = makeController(transport: transport)

        let decision = controller.decide(
            graph: videoGraph(),
            access: .privateShare(name: "Movies on NAS"),
            device: chromecast(),
            title: "The Movie"
        )

        #expect(
            decision == .declined(
                .privateShareUnreachable("Movies on NAS")
            )
        )
        let explanation = decision.explanation
        #expect(explanation?.contains("Movies on NAS") == true)
        #expect(explanation?.contains("can't reach") == true)

        // The refusal never reaches the transport.
        _ = controllerWithTransport.decide(
            graph: videoGraph(),
            access: .privateShare(name: "Movies on NAS"),
            device: chromecast(),
            title: "The Movie"
        )
        #expect(transport.recordedLoads.isEmpty)
    }

    @Test("Casting requires the Pro entitlement")
    @MainActor
    func proRequired() async throws {
        let transport = MockCastTransport()
        let controller = makeController(pro: false, transport: transport)

        let decision = controller.decide(
            graph: videoGraph(),
            access: .publiclyReachable(castURL),
            device: chromecast(),
            title: "The Movie"
        )
        #expect(decision == .declined(.proRequired))
        #expect(
            decision.explanation?.contains("PlayItRight Pro") == true
        )

        let cast = try await controller.cast(
            graph: videoGraph(),
            access: .publiclyReachable(castURL),
            device: chromecast(),
            title: "The Movie"
        )
        #expect(cast == .declined(.proRequired))
        #expect(!controller.isCasting)
        #expect(transport.recordedLoads.isEmpty)
    }

    @Test("An unreachable receiver is declined before negotiation")
    @MainActor
    func unreachableDevice() {
        let controller = makeController()

        let decision = controller.decide(
            graph: videoGraph(),
            access: .publiclyReachable(castURL),
            device: chromecast(name: "Bedroom", reachable: false),
            title: "The Movie"
        )

        #expect(
            decision == .declined(.deviceUnreachable("Bedroom"))
        )
    }

    @Test("Discovery sorts receivers by name and caches them")
    @MainActor
    func discoverySortsDevices() async throws {
        let transport = MockCastTransport(
            devices: [
                GoogleCastDevice(id: "b", name: "Bedroom"),
                GoogleCastDevice(id: "a", name: "Attic"),
                GoogleCastDevice(id: "c", name: "Cast Audio", kind: .chromecastAudio)
            ]
        )
        let controller = makeController(transport: transport)

        let devices = try await controller.discoverDevices()

        #expect(devices.map(\.name) == ["Attic", "Bedroom", "Cast Audio"])
        #expect(controller.devices == devices)
    }

    @Test("A transport failure is surfaced rather than hidden")
    @MainActor
    func transportFailure() async {
        let transport = MockCastTransport(
            loadError: .transport("receiver went away")
        )
        let controller = makeController(transport: transport)

        do {
            _ = try await controller.cast(
                graph: videoGraph(),
                access: .publiclyReachable(castURL),
                device: chromecast(),
                title: "The Movie"
            )
            Issue.record("Expected the transport failure to throw.")
        } catch let error as GoogleCastError {
            #expect(error == .transport("receiver went away"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!controller.isCasting)
    }
}
