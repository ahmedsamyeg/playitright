import Foundation
import Testing
@testable import CoreKit

@Suite("ServiceContainer Tests")
struct ServiceContainerTests {
    private protocol GreetingService: Sendable {
        func greeting() -> String
    }

    private struct GreetingServiceImplementation: GreetingService {
        let text: String

        func greeting() -> String { text }
    }

    private final class CounterService: @unchecked Sendable {
        let id = UUID()

        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private final class SingletonService: @unchecked Sendable {}

    private struct MissingService: Sendable {}

    private struct Consumer {
        @Injected var greeting: GreetingService

        init(container: ServiceContainer) {
            _greeting = Injected(container: container)
        }
    }

    @Test("Transient registrations produce a new instance per resolution")
    func transientResolutionCreatesNewInstances() throws {
        let container = ServiceContainer()
        container.register(CounterService.self) { CounterService() }

        let first = try container.resolve(CounterService.self)
        let second = try container.resolve(CounterService.self)

        #expect(first !== second)
        #expect(first.next() == 1)
        #expect(second.next() == 1)
    }

    @Test("Singleton registrations return the same instance")
    func singletonResolutionReturnsSameInstance() throws {
        let container = ServiceContainer()
        container.register(SingletonService.self, lifetime: .singleton) { SingletonService() }

        let first = try container.resolve(SingletonService.self)
        let second = try container.resolve(SingletonService.self)

        #expect(first === second)
    }

    @Test("Registering an instance stores it as a singleton")
    func instanceRegistrationReturnsSameInstance() throws {
        let container = ServiceContainer()
        let instance = SingletonService()
        container.register(SingletonService.self, instance: instance)

        let resolved = try container.resolve(SingletonService.self)
        #expect(resolved === instance)
    }

    @Test("Protocol registrations resolve by protocol type")
    func protocolRegistration() throws {
        let container = ServiceContainer()
        container.register(GreetingService.self) {
            GreetingServiceImplementation(text: "hello")
        }

        let service = try container.resolve(GreetingService.self)
        #expect(service.greeting() == "hello")
    }

    @Test("Missing registrations throw ServiceNotFoundError")
    func missingRegistrationThrowsTypedError() {
        let container = ServiceContainer()

        #expect(throws: ServiceNotFoundError.self) {
            _ = try container.resolve(MissingService.self)
        }
    }

    @Test("Unregister removes the registration and cached singleton")
    func unregisterRemovesService() throws {
        let container = ServiceContainer()
        container.register(SingletonService.self, lifetime: .singleton) { SingletonService() }
        _ = try container.resolve(SingletonService.self)

        #expect(container.isRegistered(SingletonService.self))
        container.unregister(SingletonService.self)
        #expect(!container.isRegistered(SingletonService.self))
        #expect(throws: ServiceNotFoundError.self) {
            _ = try container.resolve(SingletonService.self)
        }
    }

    @Test("Injected resolves the property type from its container")
    func injectedPropertyWrapperResolves() {
        let container = ServiceContainer()
        container.register(GreetingService.self) {
            GreetingServiceImplementation(text: "injected")
        }

        let consumer = Consumer(container: container)
        #expect(consumer.greeting.greeting() == "injected")
    }

    @Test("Concurrent singleton resolution creates exactly one instance")
    func concurrentSingletonResolution() async {
        let container = ServiceContainer()
        container.register(SingletonService.self, lifetime: .singleton) { SingletonService() }

        let identifiers = await withTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let service = try! container.resolve(SingletonService.self)
                    return ObjectIdentifier(service)
                }
            }

            var result = Set<ObjectIdentifier>()
            for await identifier in group {
                result.insert(identifier)
            }
            return result
        }

        #expect(identifiers.count == 1)
    }

    @Test("Concurrent transient resolution does not share instances")
    func concurrentTransientResolution() async {
        let container = ServiceContainer()
        container.register(CounterService.self) { CounterService() }

        let identifiers = await withTaskGroup(of: UUID.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let service = try! container.resolve(CounterService.self)
                    return service.id
                }
            }

            var result = Set<UUID>()
            for await identifier in group {
                result.insert(identifier)
            }
            return result
        }

        #expect(identifiers.count == 100)
    }
}
