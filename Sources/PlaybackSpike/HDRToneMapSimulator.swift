import Foundation

/// Mathematical simulation of HDR-to-SDR tone-mapping pipeline (PB-16, PB-17, doc 04 §7).
/// Implements SMPTE ST 2084 (PQ) EOTF, ITU-R BT.2020 to BT.709 gamut transformation,
/// and perceptual highlight tone compression.
public struct HDRToneMapSimulator: Sendable {

    public struct RGBColor: Equatable, Sendable {
        public var r: Double
        public var g: Double
        public var b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    public struct ToneMapConfiguration: Equatable, Sendable {
        /// Peak luminance of the source HDR content in nits (cd/m²). Default: 1000.0 (HDR10 mastering standard).
        public var sourcePeakNits: Double
        /// Target peak luminance of the display in nits. Default: 100.0 (standard SDR).
        public var targetPeakNits: Double
        /// Shoulder rolloff parameter for Reinhard/Hable curve (0.0 - 1.0).
        public var shoulderRolloff: Double

        public init(
            sourcePeakNits: Double = 1000.0,
            targetPeakNits: Double = 100.0,
            shoulderRolloff: Double = 0.5
        ) {
            self.sourcePeakNits = max(100.0, sourcePeakNits)
            self.targetPeakNits = max(50.0, targetPeakNits)
            self.shoulderRolloff = shoulderRolloff
        }
    }

    public let config: ToneMapConfiguration

    public init(config: ToneMapConfiguration = ToneMapConfiguration()) {
        self.config = config
    }

    // MARK: - SMPTE ST 2084 (PQ) Constants
    private static let m1: Double = 2610.0 / 16384.0        // ~0.1593017578125
    private static let m2: Double = 2523.0 / 4096.0 * 128.0  // ~78.84375
    private static let c1: Double = 3424.0 / 4096.0         // ~0.8359375
    private static let c2: Double = 2413.0 / 4096.0 * 32.0   // ~18.8515625
    private static let c3: Double = 2392.0 / 4096.0 * 32.0   // ~18.6875

    /// SMPTE ST 2084 (PQ) Electro-Optical Transfer Function (EOTF).
    /// Converts normalized non-linear PQ signal [0, 1] to absolute luminance in nits [0, 10000].
    public static func pqEOTF(normalizedValue: Double) -> Double {
        let n = max(0.0, min(1.0, normalizedValue))
        if n == 0.0 { return 0.0 }
        let nPow = pow(n, 1.0 / m2)
        let num = max(0.0, nPow - c1)
        let den = c2 - c3 * nPow
        guard den != 0.0 else { return 10000.0 }
        let linearNormalized = pow(num / den, 1.0 / m1)
        return linearNormalized * 10000.0 // Scaled to nits
    }

    /// Inverse SMPTE ST 2084 (OETF).
    /// Converts absolute luminance in nits [0, 10000] to normalized non-linear PQ [0, 1].
    public static func pqInverseEOTF(luminanceNits: Double) -> Double {
        let l = max(0.0, min(10000.0, luminanceNits)) / 10000.0
        if l == 0.0 { return 0.0 }
        let lPow = pow(l, m1)
        let num = c1 + c2 * lPow
        let den = 1.0 + c3 * lPow
        return pow(num / den, m2)
    }

    // MARK: - ITU-R BT.2020 to BT.709 Color Matrix
    /// Transforms linear BT.2020 RGB coordinates to linear BT.709 RGB coordinates.
    public static func convertBT2020ToBT709(color: RGBColor) -> RGBColor {
        // Standard D65-adapted Rec.2020 -> Rec.709 3x3 conversion matrix:
        // [  1.6605  -0.5876  -0.0728 ]
        // [ -0.1246   1.1329  -0.0083 ]
        // [ -0.0182  -0.1006   1.1187 ]
        let r709 =  1.660491 * color.r - 0.587641 * color.g - 0.072850 * color.b
        let g709 = -0.124550 * color.r + 1.132900 * color.g - 0.008349 * color.b
        let b709 = -0.018151 * color.r - 0.100579 * color.g + 1.118730 * color.b

        return RGBColor(r: r709, g: g709, b: b709)
    }

    // MARK: - ITU-R BT.709 Transfer Function (OETF)
    /// Converts linear RGB [0, 1] to BT.709 non-linear gamma-corrected display signal [0, 1].
    public static func bt709OETF(linear: Double) -> Double {
        let v = max(0.0, min(1.0, linear))
        if v < 0.018 {
            return 4.5 * v
        } else {
            return 1.099 * pow(v, 0.45) - 0.099
        }
    }

    // MARK: - Tone Mapping Compression Curve
    /// Extended Reinhard tone-mapping curve with white point preservation.
    /// Maps input luminance [0, sourcePeakNits] to [0, targetPeakNits].
    public func toneMapLuminance(inputNits: Double) -> Double {
        let x = max(0.0, inputNits)
        let whitePoint = config.sourcePeakNits
        let mapped = (x * (1.0 + (x / (whitePoint * whitePoint)))) / (1.0 + x / config.targetPeakNits)
        return min(config.targetPeakNits, mapped)
    }

    /// Full pipeline: PQ non-linear BT.2020 input -> Tone-mapped SDR BT.709 non-linear display output.
    public func processPixel(pqInput: RGBColor) -> RGBColor {
        // Step 1: Decode PQ to linear luminance in nits (BT.2020)
        let linearR_nits = Self.pqEOTF(normalizedValue: pqInput.r)
        let linearG_nits = Self.pqEOTF(normalizedValue: pqInput.g)
        let linearB_nits = Self.pqEOTF(normalizedValue: pqInput.b)

        // Step 2: Compute input luminance Y in BT.2020
        let inputLuminanceY = 0.2627 * linearR_nits + 0.6780 * linearG_nits + 0.0593 * linearB_nits

        // Step 3: Compute tone-mapped target luminance
        let targetLuminanceY = toneMapLuminance(inputNits: inputLuminanceY)

        // Step 4: Scale RGB channels by luminance ratio to preserve hue & saturation
        let scale: Double
        if inputLuminanceY > 1e-6 {
            scale = targetLuminanceY / inputLuminanceY
        } else {
            scale = 1.0
        }

        // Linear scaled RGB in nits, normalized to target SDR peak (1.0 = targetPeakNits)
        let sdrLinearR = (linearR_nits * scale) / config.targetPeakNits
        let sdrLinearG = (linearG_nits * scale) / config.targetPeakNits
        let sdrLinearB = (linearB_nits * scale) / config.targetPeakNits

        // Step 5: Convert color gamut from BT.2020 to BT.709
        let color709 = Self.convertBT2020ToBT709(color: RGBColor(r: sdrLinearR, g: sdrLinearG, b: sdrLinearB))

        // Gamut clamp (soft-clip to avoid harsh color shifts on out-of-gamut colors)
        let clampedR = max(0.0, min(1.0, color709.r))
        let clampedG = max(0.0, min(1.0, color709.g))
        let clampedB = max(0.0, min(1.0, color709.b))

        // Step 6: Apply BT.709 display transfer function (gamma)
        return RGBColor(
            r: Self.bt709OETF(linear: clampedR),
            g: Self.bt709OETF(linear: clampedG),
            b: Self.bt709OETF(linear: clampedB)
        )
    }
}
