import Foundation
import Testing
@testable import CapKit

@Suite("CapabilityProfile Tests")
struct CapabilityProfileTests {
    private func bundledMatrix() throws -> CapabilityMatrix {
        try CapabilityMatrix.bundled()
    }

    // MARK: - Bundled data

    @Test("Bundled matrix decodes every supported generation")
    func bundledMatrixDecodesAllProfiles() throws {
        let matrix = try bundledMatrix()

        #expect(matrix.schemaVersion == 1)
        #expect(matrix.profiles.count == 3)
        #expect(matrix.profiles.map(\.generation).sorted() == [2, 3, 4])
        #expect(matrix.profile(forID: "apple-tv-4k-gen2")?.chip == "A12Z")
        #expect(matrix.profile(forID: "apple-tv-4k-gen3")?.chip == "A15")
        #expect(matrix.profile(forID: "apple-tv-4k-gen4")?.chip == "A19")
    }

    @Test("All profiles declare 4K60 output limits")
    func outputLimits() throws {
        let matrix = try bundledMatrix()

        for profile in matrix.profiles {
            #expect(profile.maxVideoOutput == "2160p60")
            #expect(profile.maxHDRVideoOutput == "2160p60")
            #expect(profile.videoCapability(for: .hevc)?.maxWidth == 3840)
            #expect(profile.videoCapability(for: .hevc)?.maxHeight == 2160)
        }
    }

    // MARK: - Codec support

    @Test("Only gen 4 hardware-decodes AV1")
    func av1HardwareSupport() throws {
        let matrix = try bundledMatrix()

        #expect(matrix.profile(forGeneration: 4)?.videoCapability(for: .av1)?.supportsHardwareDecode == true)
        #expect(matrix.profile(forGeneration: 3)?.videoCapability(for: .av1)?.supportsHardwareDecode == false)
        #expect(matrix.profile(forGeneration: 2)?.videoCapability(for: .av1)?.supportsHardwareDecode == false)
        #expect(matrix.profile(forGeneration: 2)?.videoCapability(for: .av1)?.decode == .sw)
    }

    @Test("HEVC is hardware-decoded at 10-bit on every generation")
    func hevcHardwareDecode() throws {
        let matrix = try bundledMatrix()

        for generation in 2...4 {
            let profile = try #require(matrix.profile(forGeneration: generation))
            #expect(profile.videoCapability(for: .hevc)?.supportsHardwareDecode == true)
            #expect(profile.hardwareDecodeBitDepth(for: .hevc) == 10)
        }
    }

    @Test("Software-only codecs are marked as such")
    func softwareCodecs() throws {
        let matrix = try bundledMatrix()
        let profile = try #require(matrix.profile(forGeneration: 3))

        #expect(profile.videoCapability(for: .mpeg2)?.decode == .sw)
        #expect(profile.videoCapability(for: .vc1)?.decode == .sw)
        #expect(profile.videoCapability(for: .wmv)?.decode == .sw)
        #expect(profile.videoCapability(for: .divx)?.decode == .sw)
    }

    // MARK: - Dolby Vision

    @Test("Dolby Vision profiles match the baseline matrix")
    func dolbyVisionProfiles() throws {
        let matrix = try bundledMatrix()

        let gen2 = try #require(matrix.profile(forGeneration: 2)?.videoCapability(for: .hevc))
        let gen3 = try #require(matrix.profile(forGeneration: 3)?.videoCapability(for: .hevc))
        let gen4 = try #require(matrix.profile(forGeneration: 4)?.videoCapability(for: .hevc))

        #expect(gen2.dolbyVisionProfiles == [5, 8])
        #expect(gen3.dolbyVisionProfiles == [5])
        #expect(gen4.dolbyVisionProfiles == [5, 8.1])

        #expect(gen4.supportsDolbyVision(profile: 8.1))
        #expect(!gen3.supportsDolbyVision(profile: 8.1))
        #expect(gen2.supportsDolbyVision(profile: 8))
    }

    // MARK: - HDR

    @Test("HDR formats follow the device matrix")
    func hdrFormats() throws {
        let matrix = try bundledMatrix()

        let gen2 = try #require(matrix.profile(forGeneration: 2)?.videoCapability(for: .hevc))
        let gen3 = try #require(matrix.profile(forGeneration: 3)?.videoCapability(for: .hevc))
        let gen4 = try #require(matrix.profile(forGeneration: 4)?.videoCapability(for: .hevc))

        #expect(gen4.hdrFormats.contains(.hdr10))
        #expect(gen4.hdrFormats.contains(.hdr10Plus))
        #expect(gen4.hdrFormats.contains(.hlg))
        #expect(gen3.hdrFormats.contains(.hdr10Plus))
        #expect(!gen2.hdrFormats.contains(.hdr10Plus))
        #expect(gen2.hdrFormats.contains(.hlg))
    }

    // MARK: - Audio

    @Test("Audio decode paths are declared per codec")
    func audioCapabilities() throws {
        let matrix = try bundledMatrix()
        let profile = try #require(matrix.profile(forGeneration: 3))

        #expect(profile.audioCapability(for: .aac)?.hardwareDecode == true)
        #expect(profile.audioCapability(for: .flac)?.hardwareDecode == true)
        #expect(profile.audioCapability(for: .dts)?.hardwareDecode == false)
        #expect(profile.audioCapability(for: .dts)?.softwareDecode == true)
        #expect(profile.audioCapability(for: .dts)?.passthrough == true)
        #expect(profile.audioCapability(for: .truehd)?.passthrough == true)
        #expect(profile.audioCapability(for: .ac3)?.isSupported == true)
    }

    // MARK: - Lookups and decoding

    @Test("Profiles can be looked up by id and generation")
    func profileLookups() throws {
        let matrix = try bundledMatrix()

        #expect(matrix.profile(forID: "apple-tv-4k-gen4")?.generation == 4)
        #expect(matrix.profile(forID: "missing") == nil)
        #expect(matrix.profile(forGeneration: 9) == nil)
    }

    @Test("Matrix round-trips through JSON")
    func matrixRoundTrips() throws {
        let matrix = try bundledMatrix()
        let data = try JSONEncoder().encode(matrix)
        let decoded = try CapabilityMatrix.decode(from: data)

        #expect(decoded == matrix)
    }

    @Test("Malformed JSON raises a typed error")
    func malformedJSONThrows() {
        #expect(throws: CapabilityMatrixError.self) {
            _ = try CapabilityMatrix.decode(from: Data("{}".utf8))
        }
    }

    @Test("Missing resource raises a typed error")
    func missingResourceThrows() {
        #expect(throws: CapabilityMatrixError.resourceNotFound) {
            _ = try CapabilityMatrix.bundled(in: Bundle(for: BundleMarker.self))
        }
    }
}

private final class BundleMarker {}
