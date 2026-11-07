import Foundation
import Network

// MARK: - Advertisements

/// One SSDP advertisement or search response (SRC-9, doc 03 §3).
public struct SSDPAdvertisement: Sendable, Equatable {
    /// Device description URL from the `LOCATION` header.
    public var location: URL?

    /// `SERVER` header, for diagnostics only.
    public var server: String?

    /// `ST` (search target) or `NT` (notification type).
    public var searchTarget: String?

    /// `USN` (unique service name).
    public var uniqueServiceName: String?

    /// `USER-AGENT` header.
    public var userAgent: String?

    /// `CACHE-CONTROL: max-age` in seconds.
    public var maxAge: TimeInterval?

    public init(
        location: URL? = nil,
        server: String? = nil,
        searchTarget: String? = nil,
        uniqueServiceName: String? = nil,
        userAgent: String? = nil,
        maxAge: TimeInterval? = nil
    ) {
        self.location = location
        self.server = server
        self.searchTarget = searchTarget
        self.uniqueServiceName = uniqueServiceName
        self.userAgent = userAgent
        self.maxAge = maxAge
    }

    /// Parses an SSDP response packet. Returns `nil` for notifications or
    /// malformed packets that carry neither a location nor a service name.
    public static func parse(_ data: Data) -> SSDPAdvertisement? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parse(text)
    }

    /// Parses an SSDP response packet from its text form.
    public static func parse(_ text: String) -> SSDPAdvertisement? {
        let lines = text.components(separatedBy: .newlines)
        guard let status = lines.first?.trimmingCharacters(in: .whitespaces),
              status.uppercased().hasPrefix("HTTP/") else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let separator = trimmed.firstIndex(of: ":") else {
                continue
            }
            let key = String(trimmed[..<separator])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let location = headers["location"].flatMap(URL.init(string:))
        let searchTarget = headers["st"] ?? headers["nt"]
        let usn = headers["usn"]
        guard location != nil || usn != nil || searchTarget != nil else {
            return nil
        }

        var maxAge: TimeInterval?
        if let cache = headers["cache-control"] {
            for directive in cache.split(separator: ",") {
                let parts = directive.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces)
                        .lowercased() == "max-age" else {
                    continue
                }
                maxAge = TimeInterval(
                    parts[1].trimmingCharacters(in: .whitespaces)
                )
            }
        }

        return SSDPAdvertisement(
            location: location,
            server: headers["server"],
            searchTarget: searchTarget,
            uniqueServiceName: usn,
            userAgent: headers["user-agent"],
            maxAge: maxAge
        )
    }

    /// Stable identity used to de-duplicate responses from multiple network
    /// interfaces.
    public var identity: String {
        uniqueServiceName
            ?? location?.absoluteString
            ?? searchTarget
            ?? UUID().uuidString
    }
}

// MARK: - Transport seam

/// UDP seam so SSDP discovery can be exercised without a live network.
public protocol SSDPTransporting: Sendable {
    /// Sends one `M-SEARCH` datagram and collects responses until `timeout`.
    func search(_ request: Data, timeout: TimeInterval) async throws -> [Data]
}

/// SSDP discovery over the standard multicast group (239.255.255.250:1900).
public struct UDPSearchTransport: SSDPTransporting {
    public init() {}

    public func search(
        _ request: Data,
        timeout: TimeInterval
    ) async throws -> [Data] {
        guard let port = NWEndpoint.Port(rawValue: 1900) else {
            return []
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(
            host: NWEndpoint.Host("239.255.255.250"),
            port: port,
            using: parameters
        )

        let timer = Task {
            try? await Task.sleep(
                nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)
            )
            connection.cancel()
        }
        defer {
            timer.cancel()
            connection.cancel()
        }

        try await waitForReady(connection)
        try await send(request, on: connection)

        var packets: [Data] = []
        do {
            while true {
                guard let packet = try await receive(on: connection) else {
                    break
                }
                if packet.isEmpty {
                    break
                }
                packets.append(packet)
            }
        } catch {
            // A timeout cancels the connection; whatever was collected is
            // still a useful discovery result.
        }
        return packets
    }

    private func waitForReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = SSDPResumeGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume()
                case .failed(let error):
                    gate.fail(
                        SourceAdapterError.hostUnreachable(
                            error.localizedDescription
                        )
                    )
                case .cancelled:
                    gate.fail(SourceAdapterError.cancelled)
                default:
                    break
                }
            }
            connection.start(
                queue: DispatchQueue(label: "SourceAdapters.SSDP")
            )
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: SourceAdapterError.transport(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(
                        throwing: SourceAdapterError.transport(
                            error.localizedDescription
                        )
                    )
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}

private final class SSDPResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        finish { $0?.resume() }
    }

    func fail(_ error: Error) {
        finish { $0?.resume(throwing: error) }
    }

    private func finish(
        _ action: (CheckedContinuation<Void, Error>?) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            return
        }
        finished = true
        action(continuation)
        continuation = nil
    }
}

// MARK: - Discovery

/// Discovers UPnP/DLNA media servers with an `M-SEARCH` datagram.
public struct SSDPDiscovery: Sendable {
    /// MediaServer:1 is the standard DLNA server target.
    public var searchTarget: String

    /// Maximum wait requested from devices, in seconds.
    public var mx: Int

    /// How long to collect responses.
    public var timeout: TimeInterval

    private let transport: any SSDPTransporting

    public init(
        searchTarget: String = "urn:schemas-upnp-org:device:MediaServer:1",
        mx: Int = 2,
        timeout: TimeInterval = 3,
        transport: any SSDPTransporting = UDPSearchTransport()
    ) {
        self.searchTarget = searchTarget
        self.mx = max(1, mx)
        self.timeout = max(0.1, timeout)
        self.transport = transport
    }

    /// Sends the search and returns de-duplicated advertisements.
    public func discover() async throws -> [SSDPAdvertisement] {
        let packets = try await transport.search(
            Self.searchRequest(mx: mx, searchTarget: searchTarget),
            timeout: timeout
        )

        var seen: Set<String> = []
        var results: [SSDPAdvertisement] = []
        for packet in packets {
            guard let advertisement = SSDPAdvertisement.parse(packet) else {
                continue
            }
            let identity = advertisement.identity
            guard !seen.contains(identity) else {
                continue
            }
            seen.insert(identity)
            results.append(advertisement)
        }
        return results
    }

    /// Builds the `M-SEARCH` request datagram.
    public static func searchRequest(
        mx: Int,
        searchTarget: String
    ) -> Data {
        let lines = [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: \(max(1, mx))",
            "ST: \(searchTarget)",
            "",
            ""
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

// MARK: - Device description

/// One service advertised by a UPnP device.
public struct UPnPService: Sendable, Equatable {
    public var serviceType: String
    public var serviceID: String?
    public var controlURL: URL?
    public var eventSubURL: URL?

    public init(
        serviceType: String,
        serviceID: String? = nil,
        controlURL: URL? = nil,
        eventSubURL: URL? = nil
    ) {
        self.serviceType = serviceType
        self.serviceID = serviceID
        self.controlURL = controlURL
        self.eventSubURL = eventSubURL
    }

    /// Whether this is the AVTransport/ContentDirectory service.
    public var isContentDirectory: Bool {
        serviceType.contains("ContentDirectory")
    }
}

/// The subset of a UPnP device description needed to browse a server.
public struct UPnPDeviceDescription: Sendable, Equatable {
    public var friendlyName: String?
    public var manufacturer: String?
    public var modelName: String?
    public var deviceType: String?
    public var udn: String?
    public var services: [UPnPService]

    public init(
        friendlyName: String? = nil,
        manufacturer: String? = nil,
        modelName: String? = nil,
        deviceType: String? = nil,
        udn: String? = nil,
        services: [UPnPService] = []
    ) {
        self.friendlyName = friendlyName
        self.manufacturer = manufacturer
        self.modelName = modelName
        self.deviceType = deviceType
        self.udn = udn
        self.services = services
    }

    /// The ContentDirectory service, when the device exposes one.
    public var contentDirectory: UPnPService? {
        services.first(where: \.isContentDirectory)
    }

    /// Parses a device description document, resolving relative service URLs
    /// against the description URL.
    public static func parse(
        _ data: Data,
        baseURL: URL? = nil
    ) throws -> UPnPDeviceDescription {
        let delegate = UPnPDescriptionDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SourceAdapterError.protocolViolation(
                "The UPnP device description is malformed."
            )
        }
        return delegate.makeDescription()
    }
}

private final class UPnPDescriptionDelegate: NSObject, XMLParserDelegate {
    private let baseURL: URL?
    private var builder = UPnPDeviceDescription()
    private var stack: [(name: String, text: String)] = []
    private var serviceType: String?
    private var serviceID: String?
    private var controlURL: String?
    private var eventSubURL: String?
    private var services: [UPnPService] = []
    private var friendlyName: String?
    private var manufacturer: String?
    private var modelName: String?
    private var deviceType: String?
    private var udn: String?

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func makeDescription() -> UPnPDeviceDescription {
        builder.friendlyName = friendlyName
        builder.manufacturer = manufacturer
        builder.modelName = modelName
        builder.deviceType = deviceType
        builder.udn = udn
        builder.services = services
        return builder
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last
            .map(String.init) ?? elementName
        stack.append((name, ""))
        if name == "service" {
            serviceType = nil
            serviceID = nil
            controlURL = nil
            eventSubURL = nil
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        guard !stack.isEmpty else {
            return
        }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let element = stack.popLast() else {
            return
        }
        let value = element.text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch element.name {
        case "friendlyName":
            if friendlyName == nil {
                friendlyName = value
            }
        case "manufacturer":
            if manufacturer == nil {
                manufacturer = value
            }
        case "modelName":
            if modelName == nil {
                modelName = value
            }
        case "deviceType":
            if deviceType == nil {
                deviceType = value
            }
        case "UDN":
            if udn == nil {
                udn = value
            }
        case "serviceType":
            serviceType = value
        case "serviceId":
            serviceID = value
        case "controlURL":
            controlURL = value
        case "eventSubURL":
            eventSubURL = value
        case "service":
            if let serviceType, !serviceType.isEmpty {
                services.append(
                    UPnPService(
                        serviceType: serviceType,
                        serviceID: serviceID,
                        controlURL: resolve(controlURL),
                        eventSubURL: resolve(eventSubURL)
                    )
                )
            }
        default:
            break
        }
    }

    private func resolve(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else {
            return nil
        }
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        guard let baseURL else {
            return URL(string: value)
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }
}
