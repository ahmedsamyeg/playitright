import Foundation

/// Resolves a service from a `ServiceContainer` when the wrapped property is read.
///
/// The property type is used as the registration key:
///
/// ```swift
/// @Injected var library: MediaDatabaseReader
/// ```
///
/// A container can be supplied explicitly for tests or scoped object graphs:
///
/// ```swift
/// @Injected(container: container) var library: MediaDatabaseReader
/// ```
///
/// Because Swift property wrappers cannot throw from a getter, a missing
/// registration is treated as a programmer error and traps with a diagnostic
/// message. Use `ServiceContainer.resolve(_:)` directly when recoverable
/// failure handling is required.
@propertyWrapper
public struct Injected<Value> {
    private let container: ServiceContainer

    public init(
        _ type: Value.Type = Value.self,
        container: ServiceContainer = .shared
    ) {
        self.container = container
    }

    public var wrappedValue: Value {
        do {
            return try container.resolve(Value.self)
        } catch {
            preconditionFailure(
                "Failed to resolve \(String(reflecting: Value.self)): \(error)"
            )
        }
    }
}
