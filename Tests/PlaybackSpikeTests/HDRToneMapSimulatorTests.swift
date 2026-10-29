import Testing
@testable import PlaybackSpike

@Suite("HDRToneMapSimulator Tests")
struct HDRToneMapSimulatorTests {

    @Test("SMPTE ST 2084 PQ EOTF round-trip precision")
    func testPQRoundTrip() {
        // Test key luminance reference points:
        // 0 nits, 0.005 nits (OLED black), 100 nits (reference SDR diffuse white),
        // 1000 nits (standard HDR10 peak), 4000 nits (mastering monitor peak), 10000 nits (PQ ceiling).
        let testPointsNits: [Double] = [0.0, 0.005, 0.1, 1.0, 18.0, 100.0, 203.0, 400.0, 1000.0, 4000.0, 10000.0]

        for nits in testPointsNits {
            let encodedPQ = HDRToneMapSimulator.pqInverseEOTF(luminanceNits: nits)
            #expect(encodedPQ >= 0.0 && encodedPQ <= 1.0)

            let decodedNits = HDRToneMapSimulator.pqEOTF(normalizedValue: encodedPQ)
            let relativeError = nits > 0.01 ? abs(decodedNits - nits) / nits : abs(decodedNits - nits)
            #expect(relativeError < 0.001) // < 0.1% round-trip error
        }

        // Exact standard PQ values:
        // 100 nits is approx 0.508078 in normalized PQ
        let pq100 = HDRToneMapSimulator.pqInverseEOTF(luminanceNits: 100.0)
        #expect(abs(pq100 - 0.508) < 0.005)

        // 1000 nits is approx 0.751827 in normalized PQ
        let pq1000 = HDRToneMapSimulator.pqInverseEOTF(luminanceNits: 1000.0)
        #expect(abs(pq1000 - 0.752) < 0.005)
    }

    @Test("BT.2020 to BT.709 color gamut conversion identity and bounds")
    func testColorMatrixConversion() {
        // D65 white point (1, 1, 1) in BT.2020 maps to (1, 1, 1) in BT.709
        let white2020 = HDRToneMapSimulator.RGBColor(r: 1.0, g: 1.0, b: 1.0)
        let white709 = HDRToneMapSimulator.convertBT2020ToBT709(color: white2020)
        #expect(abs(white709.r - 1.0) < 0.001)
        #expect(abs(white709.g - 1.0) < 0.001)
        #expect(abs(white709.b - 1.0) < 0.001)

        // Black (0, 0, 0) maps to (0, 0, 0)
        let black = HDRToneMapSimulator.convertBT2020ToBT709(color: HDRToneMapSimulator.RGBColor(r: 0, g: 0, b: 0))
        #expect(black.r == 0.0 && black.g == 0.0 && black.b == 0.0)
    }

    @Test("Tone mapping compression maps 1000 nits to 100 nits smoothly")
    func testToneMapCompression() {
        let simulator = HDRToneMapSimulator(config: .init(sourcePeakNits: 1000.0, targetPeakNits: 100.0))

        // Input 0 nits -> Output 0 nits
        #expect(simulator.toneMapLuminance(inputNits: 0.0) == 0.0)

        // Input 100 nits (diffuse white) maps without harsh clipping
        let mapped100 = simulator.toneMapLuminance(inputNits: 100.0)
        #expect(mapped100 > 45.0 && mapped100 < 65.0)

        // Input 1000 nits (peak highlight) compresses to <= 100 nits
        let mapped1000 = simulator.toneMapLuminance(inputNits: 1000.0)
        #expect(mapped1000 <= 100.0)
        #expect(mapped1000 > 90.0)

        // Monotonic increase (higher input nits always produces higher output)
        var lastOut: Double = -1.0
        for nits in stride(from: 0.0, through: 1000.0, by: 50.0) {
            let out = simulator.toneMapLuminance(inputNits: nits)
            #expect(out >= lastOut)
            lastOut = out
        }
    }

    @Test("Full pixel processing preserves hue and bounds output within [0, 1]")
    func testFullPixelProcessing() {
        let simulator = HDRToneMapSimulator(config: .init(sourcePeakNits: 1000.0, targetPeakNits: 100.0))

        // Test pure red highlight at 1000 nits in PQ
        let pqRed = HDRToneMapSimulator.pqInverseEOTF(luminanceNits: 1000.0)
        let inputPixel = HDRToneMapSimulator.RGBColor(r: pqRed, g: 0.0, b: 0.0)

        let outputPixel = simulator.processPixel(pqInput: inputPixel)
        #expect(outputPixel.r >= 0.0 && outputPixel.r <= 1.0)
        #expect(outputPixel.g >= 0.0 && outputPixel.g <= 1.0)
        #expect(outputPixel.b >= 0.0 && outputPixel.b <= 1.0)

        // Red is still dominant (no severe hue rotation to green or blue)
        #expect(outputPixel.r > outputPixel.g)
        #expect(outputPixel.r > outputPixel.b)
    }
}
