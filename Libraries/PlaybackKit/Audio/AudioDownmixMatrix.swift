import Foundation

/// A named channel in an ITU-R BS.775-style layout.
public enum AudioChannel: String, Codable, Sendable, CaseIterable, Hashable {
    case left
    case right
    case center
    case lfe
    case leftSurround
    case rightSurround
    case leftBack
    case rightBack
}

/// An ordered channel layout. The order is the interleaved sample order.
public struct AudioChannelLayout: Codable, Sendable, Equatable {
    public var channels: [AudioChannel]

    public init(channels: [AudioChannel]) {
        self.channels = channels
    }

    public var channelCount: Int {
        channels.count
    }

    public static let mono = AudioChannelLayout(channels: [.center])
    public static let stereo = AudioChannelLayout(channels: [.left, .right])
    public static let surround51 = AudioChannelLayout(
        channels: [.left, .right, .center, .lfe, .leftSurround, .rightSurround]
    )
    public static let surround71 = AudioChannelLayout(
        channels: [
            .left, .right, .center, .lfe,
            .leftSurround, .rightSurround,
            .leftBack, .rightBack
        ]
    )

    /// Maps a conventional channel count to its standard order.
    ///
    /// Unsupported counts are treated as the first `channelCount` channels of
    /// the 7.1 layout so decoding still produces something usable.
    public static func standard(channelCount: Int) -> AudioChannelLayout {
        switch channelCount {
        case 1:
            return .mono
        case 2:
            return .stereo
        case 3:
            return AudioChannelLayout(channels: [.left, .right, .center])
        case 6:
            return .surround51
        case 7:
            return AudioChannelLayout(
                channels: [
                    .left, .right, .center, .lfe,
                    .leftSurround, .rightSurround, .leftBack
                ]
            )
        case 8...:
            return .surround71
        default:
            return .stereo
        }
    }
}

/// ITU-R BS.775 downmix coefficients from a source layout to a target layout
/// (PB-5, PB-11, doc 04 §6).
///
/// Rows are output channels and columns are input channels. `mix(_:)` applies
/// the matrix to interleaved PCM. The center channel is fed equally to left
/// and right so dialog stays centered; the optional dialog enhancement is a
/// gain in decibels applied only to the center contribution.
public struct AudioDownmixMatrix: Sendable, Equatable {
    /// Standard BS.775 attenuation for center and surround contributions.
    public static let surroundGain = 1.0 / 2.0.squareRoot()

    /// Attenuation applied to back-surround channels folded into the sides.
    public static let backSurroundGain = 1.0 / 2.0.squareRoot()

    public let inputLayout: AudioChannelLayout
    public let outputLayout: AudioChannelLayout
    public let dialogEnhancementDB: Double

    /// `coefficients[outputIndex][inputIndex]`.
    public let coefficients: [[Double]]

    public init(
        inputLayout: AudioChannelLayout,
        outputLayout: AudioChannelLayout,
        coefficients: [[Double]],
        dialogEnhancementDB: Double = 0
    ) {
        self.inputLayout = inputLayout
        self.outputLayout = outputLayout
        self.coefficients = coefficients
        self.dialogEnhancementDB = dialogEnhancementDB
    }

    public var inputChannelCount: Int {
        inputLayout.channelCount
    }

    public var outputChannelCount: Int {
        outputLayout.channelCount
    }

    /// The gain a single input channel contributes to an output channel.
    public func coefficient(
        output: AudioChannel,
        input: AudioChannel
    ) -> Double {
        guard let outputIndex = outputLayout.channels.firstIndex(of: output),
              let inputIndex = inputLayout.channels.firstIndex(of: input) else {
            return 0
        }
        return coefficients[outputIndex][inputIndex]
    }

    /// Applies the matrix to one frame of interleaved PCM samples.
    public func mix(_ samples: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: outputChannelCount)
        for outputIndex in 0..<outputChannelCount {
            var value = 0.0
            let row = coefficients[outputIndex]
            for inputIndex in 0..<inputChannelCount {
                let sample = inputIndex < samples.count
                    ? Double(samples[inputIndex])
                    : 0
                value += row[inputIndex] * sample
            }
            output[outputIndex] = Float(value)
        }
        return output
    }

    /// Builds the BS.775 matrix for a source and target layout.
    ///
    /// - Parameters:
    ///   - input: Source channel order.
    ///   - output: Target channel order.
    ///   - dialogEnhancementDB: Extra gain for the center channel, in decibels.
    public static func ituBS775(
        from input: AudioChannelLayout,
        to output: AudioChannelLayout,
        dialogEnhancementDB: Double = 0
    ) -> AudioDownmixMatrix {
        let centerGain = surroundGain * pow(10, dialogEnhancementDB / 20)

        var coefficients = [[Double]](
            repeating: [Double](repeating: 0, count: input.channelCount),
            count: output.channelCount
        )

        for (outputIndex, outputChannel) in output.channels.enumerated() {
            for (inputIndex, inputChannel) in input.channels.enumerated() {
                coefficients[outputIndex][inputIndex] = coefficient(
                    output: outputChannel,
                    input: inputChannel,
                    outputLayout: output,
                    centerGain: centerGain
                )
            }
        }

        return AudioDownmixMatrix(
            inputLayout: input,
            outputLayout: output,
            coefficients: coefficients,
            dialogEnhancementDB: dialogEnhancementDB
        )
    }

    /// Matrix entries for one output channel.
    ///
    /// Stereo folds side surrounds directly, and folds back surrounds into
    /// them. A 5.1 target keeps its direct channels and folds 7.1 backs into
    /// the side surrounds.
    private static func coefficient(
        output: AudioChannel,
        input: AudioChannel,
        outputLayout: AudioChannelLayout,
        centerGain: Double
    ) -> Double {
        let hasLFE = outputLayout.channels.contains(.lfe)

        switch output {
        case .left, .right:
            if input == output {
                return 1
            }
            if input == .center {
                return centerGain
            }
            if input == .lfe {
                return hasLFE ? 1 : 0
            }
            let isLeft = output == .left
            if input == (isLeft ? .leftSurround : .rightSurround) {
                return surroundGain
            }
            if input == (isLeft ? .leftBack : .rightBack) {
                return surroundGain * backSurroundGain
            }
            return 0
        case .center:
            return input == .center ? 1 : 0
        case .lfe:
            return input == .lfe ? 1 : 0
        case .leftSurround, .rightSurround:
            if input == output {
                return 1
            }
            let isLeft = output == .leftSurround
            if input == (isLeft ? .leftBack : .rightBack) {
                return backSurroundGain
            }
            return 0
        case .leftBack, .rightBack:
            return input == output ? 1 : 0
        }
    }
}
