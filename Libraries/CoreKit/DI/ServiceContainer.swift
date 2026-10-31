import Foundation

/// Errors thrown when a requested service has not been registered.
public struct ServiceNotFoundError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The fully qualified name of the requested service type.
    public let serviceType: String

    public init(serviceType: String) {
        self.serviceType = serviceType
    }

    public var description: String {
        "No service registered for type '\(serviceType)'."
    }
}

/// Errors thrown when a registered factory produces an unexpected type.
public struct ServiceTypeMismatchError: Error, Equatable, Sendable, CustomStringConvertible {
    public let serviceType: String
    public let resolvedType: String

    public init(serviceType: String, resolvedType: String) {
        self.serviceType = serviceType
        self.resolvedType = resolvedType
    }

    public var description: String {
        "Service factory returned '\(resolvedType)' for requested type '\(serviceType)'."
    }
}

/// Controls how often a registered service factory is invoked.
public enum ServiceLifetime: Sendable, Equatable {
    /// A new instance is created for every resolution.
    case transient

    /// The first resolved instance is cached and returned for later resolutions.
    case singleton
}

/// A thread-safe registry for application services.
///
/// `ServiceContainer` is safe to share across tasks and threads. Factories are
/// invoked while the container's recursive lock is held, so a singleton is
/// created exactly once even under concurrent resolution. Factories may resolve
/// other services from the same container; they must not access the container
/// from another thread while being evaluated.
public final class ServiceContainer: @unchecked Sendable {
    /// The process-wide default container used by `@Injected` when no container
    /// is supplied explicitly.
    public static let shared = ServiceContainer()

    private struct Registration {
        let lifetime: ServiceLifetime
        let factory: @Sendable () -> Any
    }

    /// Boxes a prebuilt instance so it can be captured by a `@Sendable` factory
    /// without requiring the service type itself to conform to `Sendable`.
    private final class InstanceBox: @unchecked Sendable {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }
    }

    private let lock = NSRecursiveLock()
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var singletons: [ObjectIdentifier: Any] = [:]

    public init() {}

    /// Registers a service factory.
    ///
    /// - Parameters:
    ///   - type: The service type used as the registration key. Defaults to `T.self`.
    ///   - lifetime: Whether to create a new value per resolution or cache one.
    ///   - factory: A closure that creates the service value.
    public func register<T>(
        _ type: T.Type = T.self,
        lifetime: ServiceLifetime = .transient,
        factory: @escaping @Sendable () -> T
    ) {
        let key = ObjectIdentifier(type)
        lock.lock()
        defer { lock.unlock() }

        registrations[key] = Registration(
            lifetime: lifetime,
            factory: { factory() as Any }
        )

        if lifetime == .transient {
            singletons.removeValue(forKey: key)
        }
    }

    /// Registers an already-created singleton instance.
    public func register<T>(_ type: T.Type = T.self, instance: T) {
        let key = ObjectIdentifier(type)
        let box = InstanceBox(instance)
        lock.lock()
        defer { lock.unlock() }

        registrations[key] = Registration(
            lifetime: .singleton,
            factory: { box.value }
        )
        singletons[key] = instance
    }

    /// Resolves a previously registered service.
    ///
    /// - Throws: `ServiceNotFoundError` if no registration exists for `type`, or
    ///   `ServiceTypeMismatchError` if a factory returns an incompatible value.
    public func resolve<T>(_ type: T.Type = T.self) throws -> T {
        let key = ObjectIdentifier(type)
        lock.lock()
        defer { lock.unlock() }

        guard let registration = registrations[key] else {
            throw ServiceNotFoundError(serviceType: String(reflecting: type))
        }

        switch registration.lifetime {
        case .transient:
            return try cast(registration.factory(), to: type)

        case .singleton:
            if let instance = singletons[key] {
                return try cast(instance, to: type)
            }

            let instance = try cast(registration.factory(), to: type)
            singletons[key] = instance
            return instance
        }
    }

    /// Returns whether a service is registered for `type`.
    public func isRegistered<T>(_ type: T.Type = T.self) -> Bool {
        let key = ObjectIdentifier(type)
        lock.lock()
        defer { lock.unlock() }
        return registrations[key] != nil
    }

    /// Removes the registration and any cached singleton for `type`.
    public func unregister<T>(_ type: T.Type = T.self) {
        let key = ObjectIdentifier(type)
        lock.lock()
        defer { lock.unlock() }
        registrations.removeValue(forKey: key)
        singletons.removeValue(forKey: key)
    }

    /// Removes every registration and cached singleton from the container.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        registrations.removeAll()
        singletons.removeAll()
    }

    private func cast<T>(_ value: Any, to type: T.Type) throws -> T {
        guard let typed = value as? T else {
            throw ServiceTypeMismatchError(
                serviceType: String(reflecting: type),
                resolvedType: String(reflecting: Swift.type(of: value))
            )
        }
        return typed
    }
}
