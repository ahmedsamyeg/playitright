import Foundation

/// Errors raised while loading the bundled capability matrix.
public enum CapabilityMatrixError: Error, Equatable, Sendable, CustomStringConvertible {
    case resourceNotFound
    case invalidData(String)

    public var description: String {
        switch self {
        case .resourceNotFound:
            return "Capabilities.json was not found in the CapKit bundle."
        case .invalidData(let message):
            return "Capabilities.json could not be decoded: \(message)"
        }
    }
}

/// The bundled capability matrix for the supported Apple TV fleet.
///
/// This is Layer 1 of `CapabilityRegistry` (PB-8): static data that runtime
/// probes may override. Keep `Capabilities.json` in sync with every new
/// supported Apple TV model (PB-9).
public struct CapabilityMatrix: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let profiles: [DeviceCapabilityProfile]

    public init(schemaVersion: Int, profiles: [DeviceCapabilityProfile]) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }

    public func profile(forID id: String) -> DeviceCapabilityProfile? {
        profiles.first { $0.id == id }
    }

    public func profile(forGeneration generation: Int) -> DeviceCapabilityProfile? {
        profiles.first { $0.generation == generation }
    }

    /// Decodes a matrix from raw JSON data.
    public static func decode(from data: Data) throws -> CapabilityMatrix {
        do {
            return try JSONDecoder().decode(CapabilityMatrix.self, from: data)
        } catch {
            throw CapabilityMatrixError.invalidData(String(describing: error))
        }
    }

    /// Loads the matrix bundled with `CapKit`.
    public static func bundled(in bundle: Bundle = .capKit) throws -> CapabilityMatrix {
        guard let url = bundle.url(forResource: "Capabilities", withExtension: "json") else {
            throw CapabilityMatrixError.resourceNotFound
        }
        do {
            return try decode(from: Data(contentsOf: url))
        } catch let error as CapabilityMatrixError {
            throw error
        } catch {
            throw CapabilityMatrixError.invalidData(String(describing: error))
        }
    }
}

public extension Bundle {
    /// The bundle containing CapKit's resources.
    static var capKit: Bundle {
        Bundle(for: CapKitBundleToken.self)
    }
}

private final class CapKitBundleToken {}
