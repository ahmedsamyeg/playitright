#include <metal_stdlib>
using namespace metal;

// PQ (SMPTE ST 2084) EOTF: normalized signal -> linear light (0...1 of 10,000 nits).
static inline float pqToLinear(float value) {
    const float m1 = 2610.0 / 16384.0;
    const float m2 = (2523.0 / 4096.0) * 128.0;
    const float c1 = 3424.0 / 4096.0;
    const float c2 = (2413.0 / 4096.0) * 32.0;
    const float c3 = (2392.0 / 4096.0) * 32.0;

    float e = max(value, 0.0);
    float p = pow(e, 1.0 / m2);
    return pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
}

// HLG inverse OETF: normalized signal -> linear light.
static inline float hlgToLinear(float value) {
    const float a = 0.17883277;
    const float b = 1.0 - 4.0 * a;
    const float c = 0.5 - a * log(4.0 * a);

    float e = max(value, 0.0);
    if (e <= 0.5) {
        return (e * e) / 3.0;
    }
    return (exp((e - c) / a) + b) / 12.0;
}

// BT.1886 / sRGB-ish display encoding.
static inline float linearToDisplay(float value) {
    return pow(clamp(value, 0.0, 1.0), 1.0 / 2.4);
}

// mode: 0 = PQ -> SDR, 1 = HLG -> SDR, 2 = passthrough.
kernel void toneMapHDR(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float &targetNits [[buffer(0)]],
    constant uint &mode [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    float4 source = input.read(gid);
    float3 rgb = source.rgb;

    if (mode == 0) {
        float3 linear = float3(
            pqToLinear(rgb.r),
            pqToLinear(rgb.g),
            pqToLinear(rgb.b)
        );
        // Normalize absolute light to the display's peak.
        linear *= 10000.0 / max(targetNits, 1.0);
        rgb = float3(
            linearToDisplay(linear.r),
            linearToDisplay(linear.g),
            linearToDisplay(linear.b)
        );
    } else if (mode == 1) {
        float3 linear = float3(
            hlgToLinear(rgb.r),
            hlgToLinear(rgb.g),
            hlgToLinear(rgb.b)
        );
        linear *= 1000.0 / max(targetNits, 1.0);
        rgb = float3(
            linearToDisplay(linear.r),
            linearToDisplay(linear.g),
            linearToDisplay(linear.b)
        );
    }

    output.write(float4(rgb, source.a), gid);
}
