import CoreVideo
import Foundation
import Metal

private final class MetalBundleToken {}

public enum MetalToneMapError: Error, LocalizedError, Equatable {
    case deviceUnavailable
    case libraryUnavailable(String)
    case functionUnavailable
    case pipelineCreationFailed(String)
    case unsupportedPixelFormat(OSType)
    case textureCreationFailed
    case pixelBufferCreationFailed(Int32)
    case commandEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "No Metal device is available."
        case .libraryUnavailable(let message):
            return "The Metal shader library could not be loaded: \(message)"
        case .functionUnavailable:
            return "The tone-mapping kernel is missing from the Metal library."
        case .pipelineCreationFailed(let message):
            return "The Metal tone-mapping pipeline could not be created: \(message)"
        case .unsupportedPixelFormat(let format):
            return "Pixel format '\(format)' is not supported by the tone mapper."
        case .textureCreationFailed:
            return "Could not create a Metal texture from the pixel buffer."
        case .pixelBufferCreationFailed(let status):
            return "Could not create an output pixel buffer (status \(status))."
        case .commandEncodingFailed:
            return "Could not encode the tone-mapping command."
        }
    }
}

/// Applies PQ/HLG tone-mapping on the GPU (PB-16, doc 04 §7).
///
/// The shader maps absolute HDR light to the configured display peak and
/// writes BT.1886-encoded output. It is used by R3 when the system compositor
/// cannot do the transform, and it keeps frames on the GPU.
public final class MetalToneMapper: @unchecked Sendable {
    public enum Curve: UInt32, Sendable, CaseIterable {
        case pq = 0
        case hlg = 1
        case passthrough = 2
    }

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else {
            throw MetalToneMapError.deviceUnavailable
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw MetalToneMapError.pipelineCreationFailed(
                "could not create a command queue"
            )
        }
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try Self.makeLibrary(device: device)
        } catch {
            throw MetalToneMapError.libraryUnavailable(
                error.localizedDescription
            )
        }
        guard let function = library.makeFunction(name: "toneMapHDR") else {
            throw MetalToneMapError.functionUnavailable
        }
        do {
            pipelineState = try device.makeComputePipelineState(
                function: function
            )
        } catch {
            throw MetalToneMapError.pipelineCreationFailed(
                error.localizedDescription
            )
        }
    }

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let bundle = Bundle(for: MetalBundleToken.self)
        if let library = try? device.makeDefaultLibrary(bundle: bundle),
           library.makeFunction(name: "toneMapHDR") != nil {
            return library
        }
        return try device.makeLibrary(source: fallbackShaderSource, options: nil)
    }

    /// Tone-maps a BGRA pixel buffer and returns a new BGRA pixel buffer.
    public func toneMap(
        pixelBuffer: CVPixelBuffer,
        targetNits: Double = 100,
        curve: Curve = .pq
    ) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else {
            throw MetalToneMapError.unsupportedPixelFormat(format)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let inputTexture = try texture(
            from: pixelBuffer,
            pixelFormat: .bgra8Unorm
        )

        var outputBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &outputBuffer
        )
        guard status == kCVReturnSuccess, let outputBuffer else {
            throw MetalToneMapError.pixelBufferCreationFailed(status)
        }

        let outputTexture = try texture(
            from: outputBuffer,
            pixelFormat: .bgra8Unorm
        )
        try run(
            input: inputTexture,
            output: outputTexture,
            targetNits: targetNits,
            curve: curve
        )
        return outputBuffer
    }

    /// Runs the kernel on two textures. Exposed for GPU tests and previews.
    public func run(
        input: MTLTexture,
        output: MTLTexture,
        targetNits: Double,
        curve: Curve
    ) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalToneMapError.commandEncodingFailed
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        var nits = Float(max(1, targetNits))
        var mode = curve.rawValue
        encoder.setBytes(&nits, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&mode, length: MemoryLayout<UInt32>.size, index: 1)

        let threadWidth = pipelineState.threadExecutionWidth
        let threadHeight = max(1, pipelineState.maxTotalThreadsPerThreadgroup / threadWidth)
        let threadsPerGroup = MTLSize(
            width: threadWidth,
            height: threadHeight,
            depth: 1
        )
        let groups = MTLSize(
            width: (output.width + threadWidth - 1) / threadWidth,
            height: (output.height + threadHeight - 1) / threadHeight,
            depth: 1
        )
        encoder.dispatchThreadgroups(
            groups,
            threadsPerThreadgroup: threadsPerGroup
        )
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status == .error {
            throw MetalToneMapError.commandEncodingFailed
        }
    }

    private func texture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLTexture {
        if textureCache == nil {
            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(
                kCFAllocatorDefault,
                nil,
                device,
                nil,
                &cache
            )
            guard status == kCVReturnSuccess else {
                throw MetalToneMapError.textureCreationFailed
            }
            textureCache = cache
        }
        guard let textureCache else {
            throw MetalToneMapError.textureCreationFailed
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw MetalToneMapError.textureCreationFailed
        }
        return texture
    }

    /// Kept in sync with `Shaders.metal` for builds where the default library
    /// is not bundled (for example a stripped test host).
    private static let fallbackShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

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

    static inline float hlgToLinear(float value) {
        const float a = 0.17883277;
        const float b = 1.0 - 4.0 * a;
        const float c = 0.5 - a * log(4.0 * a);
        float e = max(value, 0.0);
        if (e <= 0.5) { return (e * e) / 3.0; }
        return (exp((e - c) / a) + b) / 12.0;
    }

    static inline float linearToDisplay(float value) {
        return pow(clamp(value, 0.0, 1.0), 1.0 / 2.4);
    }

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
    """
}
