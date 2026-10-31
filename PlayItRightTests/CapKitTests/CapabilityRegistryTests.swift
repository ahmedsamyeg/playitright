import Foundation
import Testing
@testable import CapKit

@Suite("CapabilityRegistry Tests")
struct CapabilityRegistryTests {
    private func matrix() throws -> CapabilityMatrix {
        try CapabilityMatrix.bundled()
    }

    private func registry(for generation: Int) throws -> CapabilityRegistry {
        let profile = try #require(try matrix().profile(forGeneration: generation))
        return CapabilityRegistry(profile: profile)
    }

    // MARK: - Hardware decode

    @Test("Hardware decode answers differ by generation")
    func hardwareDecodePerGeneration() throws {
        #expect(try registry(for: 4).canHardwareDecode(codec: .av1, bitDepth: 10))
        #expect(try !registry(for: 3).canHardwareDecode(codec: .av1, bitDepth: 10))
        #expect(try !registry(for: 2).canHardwareDecode(codec: .av1, bitDepth: 10))

        for generation in 2...4 {
            #expect(try registry(for: generation).canHardwareDecode(codec: .hevc, bitDepth: 10))
            #expect(try registry(for: generation).canHardwareDecode(codec: .h264, bitDepth: 8))
        }
    }

    @Test("Bit depth limits are enforced")
    func bitDepthLimits() throws {
        let registry = try registry(for: 3)

        #expect(registry.canHardwareDecode(codec: .hevc, bitDepth: 10))
        #expect(!registry.canHardwareDecode(codec: .hevc, bitDepth: 12))
        #expect(registry.canHardwareDecode(codec: .h264, bitDepth: 8))
        #expect(!registry.canHardwareDecode(codec: .h264, bitDepth: 10))
    }

    @Test("Resolution limits are enforced")
    func resolutionLimits() throws {
        let registry = try registry(for: 3)

        #expect(registry.canHardwareDecode(codec: .hevc, bitDepth: 10, resolution: .uhd4K))
        #expect(registry.canHardwareDecode(codec: .hevc, bitDepth: 10, resolution: .hd1080p))
        #expect(!registry.canHardwareDecode(
            codec: .hevc,
            bitDepth: 10,
            resolution: VideoResolution(width: 7680, height: 4320)
        ))
    }

    @Test("Dolby Vision support follows the device matrix")
    func dolbyVisionSupport() throws {
        let gen2 = try registry(for: 2)
        let gen3 = try registry(for: 3)
        let gen4 = try registry(for: 4)

        #expect(gen4.supportsDolbyVision(profile: 5))
        #expect(gen4.supportsDolbyVision(profile: 8.1))
        #expect(gen3.supportsDolbyVision(profile: 5))
        #expect(!gen3.supportsDolbyVision(profile: 8.1))
        #expect(gen2.supportsDolbyVision(profile: 8))

        #expect(gen4.canHardwareDecode(
            codec: .hevc,
            bitDepth: 10,
            dolbyVisionProfile: 8.1
        ))
        #expect(!gen3.canHardwareDecode(
            codec: .hevc,
            bitDepth: 10,
            dolbyVisionProfile: 8.1
        ))
    }

    // MARK: - Software fallback

    @Test("Unsupported hardware codecs fall back to software")
    func softwareFallback() throws {
        let registry = try registry(for: 2)

        #expect(registry.canSoftwareDecode(codec: .av1, bitDepth: 10))
        #expect(registry.decodePath(codec: .av1, bitDepth: 10) == .software)
        #expect(registry.decodePath(codec: .hevc, bitDepth: 10) == .hardware)
    }

    @Test("Formats beyond the profile limits are unsupported")
    func unsupportedFormat() throws {
        let registry = try registry(for: 3)

        #expect(registry.decodePath(codec: .vvc, bitDepth: 12) == .unsupported)
    }

    // MARK: - Runtime overrides

    @Test("Runtime probes override the bundled matrix")
    func runtimeProbeOverridesData() throws {
        let gen2 = try registry(for: 2)
        let override = VideoProbeResult(
            format: VideoProbeFormat(codec: .av1, bitDepth: 10),
            hardwareDecode: true,
            softwareDecode: true,
            hardwareEncode: false,
            probedAt: Date(timeIntervalSince1970: 0)
        )
        let overridden = CapabilityRegistry(profile: gen2.profile, probeResults: [override])

        #expect(!gen2.canHardwareDecode(codec: .av1, bitDepth: 10))
        #expect(overridden.canHardwareDecode(codec: .av1, bitDepth: 10))
    }

    @Test("A probe reporting no hardware decode wins over the data layer")
    func probeCanDisableHardware() throws {
        let gen4 = try registry(for: 4)
        let override = VideoProbeResult(
            format: VideoProbeFormat(codec: .hevc, bitDepth: 10),
            hardwareDecode: false,
            softwareDecode: true,
            hardwareEncode: false,
            probedAt: Date(timeIntervalSince1970: 0)
        )
        let overridden = CapabilityRegistry(profile: gen4.profile, probeResults: [override])

        #expect(!overridden.canHardwareDecode(codec: .hevc, bitDepth: 10))
        #expect(overridden.canSoftwareDecode(codec: .hevc, bitDepth: 10))
        #expect(overridden.decodePath(codec: .hevc, bitDepth: 10) == .software)
    }

    @Test("Probe encode results override the data layer")
    func probeOverridesEncoding() throws {
        let registry = try registry(for: 3)
        let override = VideoProbeResult(
            format: VideoProbeFormat(codec: .av1, bitDepth: 10),
            hardwareDecode: false,
            softwareDecode: true,
            hardwareEncode: true,
            probedAt: Date(timeIntervalSince1970: 0)
        )
        let overridden = CapabilityRegistry(profile: registry.profile, probeResults: [override])

        #expect(!registry.canHardwareEncode(codec: .av1, bitDepth: 10))
        #expect(overridden.canHardwareEncode(codec: .av1, bitDepth: 10))
    }

    // MARK: - Developer override

    @Test("Force software path disables hardware for every codec")
    func forceSoftwarePath() throws {
        let registry = try registry(for: 4)

        for codec in VideoCodec.allCases {
            registry.setForceSoftwarePath(true)

            #expect(!registry.canHardwareDecode(codec: codec, bitDepth: 8, resolution: .hd1080p))
            #expect(!registry.canHardwareEncode(codec: codec, bitDepth: 8))
            #expect(registry.canSoftwareDecode(codec: codec, bitDepth: 8, resolution: .hd1080p))
            #expect(registry.decodePath(codec: codec, bitDepth: 8, resolution: .hd1080p) == .software)

            registry.setForceSoftwarePath(false)
        }
    }

    @Test("Force software path can be set at construction")
    func forceSoftwarePathAtInit() throws {
        let profile = try #require(try matrix().profile(forGeneration: 4))
        let registry = CapabilityRegistry(profile: profile, forceSoftwarePath: true)

        #expect(registry.forceSoftwarePath)
        #expect(!registry.canHardwareDecode(codec: .hevc, bitDepth: 10))
    }

    // MARK: - Hardware encode

    @Test("Hardware encoding follows the matrix")
    func hardwareEncoding() throws {
        let registry = try registry(for: 3)

        #expect(registry.canHardwareEncode(codec: .h264, bitDepth: 8))
        #expect(registry.canHardwareEncode(codec: .hevc, bitDepth: 10))
        #expect(!registry.canHardwareEncode(codec: .av1, bitDepth: 10))
        #expect(!registry.canHardwareEncode(codec: .hevc, bitDepth: 12))
    }

    // MARK: - Device support

    @Test("Supported model identifiers resolve to profiles")
    func resolvesSupportedModels() throws {
        let matrix = try matrix()

        #expect(try CapabilityRegistry.resolveProfile(
            modelIdentifier: "AppleTV11,1",
            from: matrix
        ).generation == 2)
        #expect(try CapabilityRegistry.resolveProfile(
            modelIdentifier: "AppleTV14,1",
            from: matrix
        ).generation == 3)
        #expect(try CapabilityRegistry.resolveProfile(
            modelIdentifier: "AppleTV17,1",
            from: matrix
        ).generation == 4)
    }

    @Test("Apple TV HD and gen 1 are rejected")
    func rejectsUnsupportedModels() throws {
        let matrix = try matrix()

        #expect(throws: UnsupportedHardwareError.self) {
            _ = try CapabilityRegistry.resolveProfile(
                modelIdentifier: "AppleTV5,3",
                from: matrix
            )
        }
        #expect(throws: UnsupportedHardwareError.self) {
            _ = try CapabilityRegistry.resolveProfile(
                modelIdentifier: "AppleTV6,2",
                from: matrix
            )
        }
        #expect(throws: UnsupportedHardwareError.self) {
            _ = try CapabilityRegistry.resolveProfile(
                modelIdentifier: "AppleTV20,1",
                from: matrix
            )
        }
    }

    @Test("makeDefault uses the supplied model and matrix")
    func makeDefault() throws {
        let registry = try CapabilityRegistry.makeDefault(
            modelIdentifier: "AppleTV14,1",
            matrix: try matrix()
        )

        #expect(registry.profile.generation == 3)
        #expect(registry.canHardwareDecode(codec: .hevc, bitDepth: 10))
    }
}
