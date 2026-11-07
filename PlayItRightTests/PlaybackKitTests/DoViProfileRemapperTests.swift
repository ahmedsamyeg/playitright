import Foundation
import Testing
@testable import PlaybackKit

/// Dolby Vision profile remapping tests (TASK-4.3, doc 04 §7).
@Suite
struct DoViProfileRemapperTests {
    // MARK: - Fixtures

    /// A realistic Profile 7 RPU: dual-layer profile, NLQ present, BL level.
    private static var profile7RPU: DoViRPU {
        DoViRPU(
            vuiParametersPresent: false,
            elSpatialResamplingFilterPresent: true,
            disableResidual: false,
            vdrRPUProfile: 0,
            vdrRPULevel: 6,
            vdrRPUID: 1,
            colorTransform: true,
            targetDisplayIndex: 0,
            targetTransferCharacteristics: 2,
            nlq: DoViNLQ(methodID: 1, regressorID: 0),
            trailerBits: [0x5A, 0xA5]
        )
    }

    /// A Profile 8.0 RPU: single layer with NLQ (IPT-based).
    private static var profile8RPU: DoViRPU {
        DoViRPU(
            vuiParametersPresent: true,
            elSpatialResamplingFilterPresent: false,
            disableResidual: false,
            vdrRPUProfile: 1,
            vdrRPULevel: 1,
            vdrRPUID: 3,
            colorTransform: true,
            targetDisplayIndex: 0,
            targetTransferCharacteristics: 2,
            nlq: DoViNLQ(methodID: 2, regressorID: 1),
            trailerBits: [0xFF]
        )
    }

    private static func encodedRPU(_ rpu: DoViRPU) -> [UInt8] {
        (try? DoViProfileRemapper.encode(rpu: rpu)) ?? []
    }

    // MARK: - Roundtrip

    @Test
    func roundTripsProfile7() throws {
        let decoded = try DoViProfileRemapper.parse(payload: Self.encodedRPU(Self.profile7RPU))
        #expect(decoded == Self.profile7RPU)
        #expect(decoded.inferredProfile == .profile7)
    }

    @Test
    func roundTripsProfile8() throws {
        let decoded = try DoViProfileRemapper.parse(payload: Self.encodedRPU(Self.profile8RPU))
        #expect(decoded == Self.profile8RPU)
        #expect(decoded.inferredProfile == .profile8)
    }

    // MARK: - RPU scanning

    @Test
    func findsRPUPayloadsBetweenStartCodes() throws {
        let payload = Self.encodedRPU(Self.profile8RPU)
        var stream: [UInt8] = [0x00, 0x00, 0x01, 0x20]
        stream.append(contentsOf: Array(repeating: 0x11, count: 4))
        stream.append(contentsOf: payload)
        stream.append(contentsOf: [0x00, 0x00, 0x01, 0x21, 0x99])

        let ranges = DoViProfileRemapper.findRPUPayloads(in: stream)
        #expect(ranges.count == 1)
        let range = try #require(ranges.first)
        #expect(Array(stream[range]) == payload)
    }

    @Test
    func scansWholeStreamWhenNoStartCodeFollows() throws {
        let payload = Self.encodedRPU(Self.profile7RPU)
        var stream: [UInt8] = [0xEE, 0xDD]
        stream.append(contentsOf: payload)
        stream.append(contentsOf: [0xCC])

        let ranges = DoViProfileRemapper.findRPUPayloads(in: stream)
        #expect(ranges.count == 1)
        let range = try #require(ranges.first)
        // The range extends to the next start code, so it includes the
        // stray byte appended after the payload.
        #expect(Array(stream[range]) == payload + [0xCC])
    }

    // MARK: - Remapping rules

    @Test
    func convertsProfile7ToProfile81() throws {
        let remapped = try DoViProfileRemapper.remapToProfile81(
            payload: Self.encodedRPU(Self.profile7RPU)
        )
        let decoded = try DoViProfileRemapper.parse(payload: remapped)
        #expect(decoded.inferredProfile == .profile81)
        #expect(decoded.vdrRPUProfile == 1)
        #expect(decoded.nlq == nil)
        #expect(decoded.targetTransferCharacteristics == 2)
        #expect(decoded.vdrRPUID == 0)
        // Master metadata survives the rewrite.
        #expect(decoded.trailerBits == Self.profile7RPU.trailerBits)
        #expect(decoded.vdrRPULevel == Self.profile7RPU.vdrRPULevel)
        #expect(decoded.vdrRPUID == 0)
    }

    @Test
    func convertsProfile8ToProfile81() throws {
        let remapped = try DoViProfileRemapper.remapToProfile81(
            payload: Self.encodedRPU(Self.profile8RPU)
        )
        let decoded = try DoViProfileRemapper.parse(payload: remapped)
        #expect(decoded.inferredProfile == .profile81)
        #expect(decoded.nlq == nil)
        #expect(decoded.disableResidual == true)
        #expect(decoded.targetTransferCharacteristics == 2)
        #expect(decoded.trailerBits == Self.profile8RPU.trailerBits)
    }

    @Test
    func idempotentOnAlreadyProfile81() throws {
        let remapped = try DoViProfileRemapper.remapToProfile81(
            payload: Self.encodedRPU(Self.profile8RPU)
        )
        let nearly = try DoViProfileRemapper.remapToProfile81(payload: remapped)
        #expect(nearly == remapped)
    }

    @Test
    func rejectsProfile5Passthrough() throws {
        var rpu = Self.profile7RPU
        rpu.vdrRPUProfile = 1
        rpu.colorTransform = false
        var caught: Error?
        do {
            _ = try DoViProfileRemapper.remapToProfile81(rpu: rpu)
        } catch {
            caught = error
        }
        let caughtMessage = try #require(caught)
        #expect(String(describing: caughtMessage) == String(describing: DoViProfileRemapperError.profileNotRemappable(vdrProfile: 1)))
    }

    // MARK: - Stream rewrite

    @Test
    func remapsEveryRPUInAStream() throws {
        let first = Self.encodedRPU(Self.profile7RPU)
        let second = Self.encodedRPU(Self.profile8RPU)
        var stream: [UInt8] = [0x00, 0x00, 0x01, 0x20, 0x33]
        stream.append(contentsOf: first)
        stream.append(contentsOf: [0x00, 0x00, 0x01, 0x21, 0x44])
        stream.append(contentsOf: second)

        let output = try DoViProfileRemapper.remapStreamToProfile81(stream)
        let ranges = DoViProfileRemapper.findRPUPayloads(in: output)
        #expect(ranges.count == 2)
        for range in ranges {
            let rpu = try DoViProfileRemapper.parse(payload: Array(output[range]))
            #expect(rpu.inferredProfile == .profile81)
        }
    }

    @Test
    func leavesNonRPUDataUntouched() throws {
        let payload = Self.encodedRPU(Self.profile8RPU)
        var stream: [UInt8] = [0x00, 0x00, 0x01, 0x26, 0x55, 0x66]
        stream.append(contentsOf: payload)
        stream.append(contentsOf: [0x00, 0x00, 0x01, 0x27, 0x77])

        let output = try DoViProfileRemapper.remapStreamToProfile81(stream)
        // Header NAL bytes at the start and the trailing NAL survive.
        let head = Array(output[0..<6])
        #expect(head == [0x00, 0x00, 0x01, 0x26, 0x55, 0x66])
        #expect(output.suffix(5) == [0x00, 0x00, 0x01, 0x27, 0x77])
        // The rewritten middle is a valid 8.1 RPU.
        let ranges = DoViProfileRemapper.findRPUPayloads(in: output)
        let rpu = try DoViProfileRemapper.parse(
            payload: Array(output[try #require(ranges.first)])
        )
        #expect(rpu.inferredProfile == .profile81)
    }

    // MARK: - Rejections

    @Test
    func rejectsShortPayload() throws {
        var caught: Error?
        do {
            _ = try DoViProfileRemapper.parse(payload: [0x01])
        } catch {
            caught = error
        }
        #expect(String(describing: try #require(caught)) == String(describing: DoViProfileRemapperError.tooShort))
    }

    @Test
    func rejectsMagicMismatch() throws {
        let bad: [UInt8] = [0x99, 0x88, 0x77, 0x66, 0x25, 0x08, 0x80, 0xFF]
        var caught: Error?
        do {
            _ = try DoViProfileRemapper.parse(payload: bad)
        } catch {
            caught = error
        }
        #expect(String(describing: try #require(caught)) == String(describing: DoViProfileRemapperError.magicMismatch))
    }

    @Test
    func rejectsFragmentedRPU() {
        // Hand-build an RPU whose header declares a fragmented unit: the
        // stream-breaking conversion is refused rather than half-rewritten.
        var writer = BitwiseWriter()
        writer.writeBytes(DoViProfileRemapper.rpuMagic)
        writer.write(0x25, width: 8)   // rpu_nal_prefix
        writer.write(2, width: 2)      // rpu_type
        writer.write(0, width: 1)      // vui
        writer.write(0, width: 1)      // el spatial
        writer.write(1, width: 1)      // disable residual
        writer.write(1, width: 4)      // profile: single layer
        writer.write(1, width: 8)      // level
        writer.write(0, width: 4)      // id
        writer.write(0, width: 1)      // colorTransform = false
        writer.write(1, width: 1)      // fragmented = true
        let crafted = writer.alignedBytes()
        #expect(throws: DoViProfileRemapperError.fragmentedRPUUnsupported) {
            _ = try DoViProfileRemapper.parse(payload: crafted)
        }
    }
}
