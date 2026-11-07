import Foundation

// MARK: - DIDL-Lite

/// One `res` element inside a DIDL-Lite object.
public struct DIDLResource: Sendable, Equatable {
    public var url: URL
    public var protocolInfo: String?
    public var sizeBytes: Int64?
    public var durationSeconds: Double?
    public var resolution: String?

    public init(
        url: URL,
        protocolInfo: String? = nil,
        sizeBytes: Int64? = nil,
        durationSeconds: Double? = nil,
        resolution: String? = nil
    ) {
        self.url = url
        self.protocolInfo = protocolInfo
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.resolution = resolution
    }
}

/// One container or item from a ContentDirectory browse response.
public struct DIDLObject: Sendable, Equatable {
    public var id: String
    public var parentID: String
    public var title: String
    public var upnpClass: String
    public var isContainer: Bool
    public var resources: [DIDLResource]
    public var date: Date?

    public init(
        id: String,
        parentID: String,
        title: String,
        upnpClass: String,
        isContainer: Bool,
        resources: [DIDLResource] = [],
        date: Date? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.upnpClass = upnpClass
        self.isContainer = isContainer
        self.resources = resources
        self.date = date
    }

    /// Whether the object describes a video item.
    public var isVideo: Bool {
        upnpClass.contains("videoItem") || upnpClass.contains("movie")
    }

    /// The resource that should be streamed, preferring video.
    public var preferredResource: DIDLResource? {
        resources.first { $0.protocolInfo?.contains("video") == true }
            ?? resources.first
    }
}

/// Parsed DIDL-Lite metadata returned by `ContentDirectory:Browse`.
public struct DIDLLite: Sendable, Equatable {
    public var objects: [DIDLObject]
    public var totalMatches: Int?
    public var numberReturned: Int?

    public init(
        objects: [DIDLObject] = [],
        totalMatches: Int? = nil,
        numberReturned: Int? = nil
    ) {
        self.objects = objects
        self.totalMatches = totalMatches
        self.numberReturned = numberReturned
    }

    /// Containers in document order.
    public var containers: [DIDLObject] {
        objects.filter(\.isContainer)
    }

    /// Playable items in document order.
    public var items: [DIDLObject] {
        objects.filter { !$0.isContainer }
    }

    /// Parses a DIDL-Lite document.
    public static func parse(_ xml: Data) throws -> DIDLLite {
        let delegate = DIDLDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SourceAdapterError.protocolViolation(
                "The DIDL-Lite metadata is malformed."
            )
        }
        return DIDLLite(objects: delegate.objects)
    }
}

private final class DIDLDelegate: NSObject, XMLParserDelegate {
    var objects: [DIDLObject] = []

    private var stack: [(name: String, text: String)] = []
    private var current: DIDLObject?
    private var resourceAttributes: [String: String]?

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

        switch name {
        case "container", "item":
            current = DIDLObject(
                id: attributeDict["id"] ?? "",
                parentID: attributeDict["parentID"] ?? "-1",
                title: "",
                upnpClass: "",
                isContainer: name == "container"
            )
        case "res":
            resourceAttributes = attributeDict
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
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
        case "title":
            current?.title = value
        case "class":
            current?.upnpClass = value
        case "date":
            current?.date = UPnPDate.parse(value)
        case "res":
            appendResource(urlText: value)
            resourceAttributes = nil
        case "container", "item":
            if let current {
                objects.append(current)
            }
            current = nil
        default:
            break
        }
    }

    private func appendResource(urlText: String) {
        guard var object = current,
              !urlText.isEmpty,
              let url = URL(string: urlText) else {
            return
        }
        let attributes = resourceAttributes ?? [:]
        object.resources.append(
            DIDLResource(
                url: url,
                protocolInfo: attributes["protocolInfo"],
                sizeBytes: attributes["size"].flatMap(Int64.init),
                durationSeconds: attributes["duration"]
                    .flatMap(UPnPDuration.parse),
                resolution: attributes["resolution"]
            )
        )
        current = object
    }
}

/// Parses UPnP durations such as `0:01:02.500` or `01:02:03`.
public enum UPnPDuration {
    public static func parse(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3_600 + minutes * 60 + seconds
    }
}

/// Parses the RFC 3339-ish dates used by some DLNA servers.
public enum UPnPDate {
    public static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter.date(from: value)
    }
}

// MARK: - ContentDirectory browse

/// One page returned by `ContentDirectory:Browse`.
public struct UPnPBrowsePage: Sendable, Equatable {
    public var objects: [DIDLObject]
    public var totalMatches: Int
    public var numberReturned: Int

    public init(
        objects: [DIDLObject] = [],
        totalMatches: Int = 0,
        numberReturned: Int = 0
    ) {
        self.objects = objects
        self.totalMatches = totalMatches
        self.numberReturned = numberReturned
    }

    /// Parses a SOAP `BrowseResponse` envelope.
    public static func parse(_ data: Data) throws -> UPnPBrowsePage {
        let delegate = BrowseResponseDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SourceAdapterError.protocolViolation(
                "The ContentDirectory response is malformed."
            )
        }
        let result = delegate.result.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if result.isEmpty {
            return UPnPBrowsePage(
                totalMatches: delegate.totalMatches ?? 0,
                numberReturned: delegate.numberReturned ?? 0
            )
        }
        let lite = try DIDLLite.parse(Data(result.utf8))
        return UPnPBrowsePage(
            objects: lite.objects,
            totalMatches: delegate.totalMatches ?? lite.objects.count,
            numberReturned: delegate.numberReturned ?? lite.objects.count
        )
    }
}

private final class BrowseResponseDelegate: NSObject, XMLParserDelegate {
    var result = ""
    var totalMatches: Int?
    var numberReturned: Int?

    private var stack: [(name: String, text: String)] = []

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
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
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
        case "Result":
            result = value
        case "TotalMatches":
            totalMatches = Int(value)
        case "NumberReturned":
            numberReturned = Int(value)
        default:
            break
        }
    }
}

// MARK: - HTTP seam

/// HTTP seam for SOAP control requests and ranged media reads.
public protocol UPnPHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession-backed UPnP transport with caching disabled.
public struct URLSessionUPnPTransport: UPnPHTTPTransport, Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public init(configuration: URLSessionConfiguration) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceAdapterError.protocolViolation(
                "The UPnP response was not HTTP."
            )
        }
        return (data, http)
    }
}

/// SOAP client for the UPnP `ContentDirectory` service (SRC-9).
public struct UPnPContentDirectoryClient: Sendable {
    public var controlURL: URL
    public var serviceType: String
    public var transport: any UPnPHTTPTransport

    public init(
        controlURL: URL,
        serviceType: String = "urn:schemas-upnp-org:service:ContentDirectory:1",
        transport: any UPnPHTTPTransport = URLSessionUPnPTransport()
    ) {
        self.controlURL = controlURL
        self.serviceType = serviceType
        self.transport = transport
    }

    /// Requests one page of direct children for `objectID`.
    public func browse(
        objectID: String,
        startIndex: Int = 0,
        requestedCount: Int = 200,
        browseFlag: String = "BrowseDirectChildren"
    ) async throws -> UPnPBrowsePage {
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue(
            "text/xml; charset=\"utf-8\"",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "\"\(serviceType)#Browse\"",
            forHTTPHeaderField: "SOAPACTION"
        )
        request.httpBody = Self.browseEnvelope(
            objectID: objectID,
            browseFlag: browseFlag,
            startIndex: startIndex,
            requestedCount: requestedCount
        )

        let (data, response) = try await transport.send(request)
        try Self.validate(response: response, data: data)
        return try UPnPBrowsePage.parse(data)
    }

    /// Builds the SOAP body, escaping the object id.
    public static func browseEnvelope(
        objectID: String,
        browseFlag: String,
        startIndex: Int,
        requestedCount: Int
    ) -> Data {
        let escaped = xmlEscape(objectID)
        let body = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body>\
        <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">\
        <ObjectID>\(escaped)</ObjectID>\
        <BrowseFlag>\(browseFlag)</BrowseFlag>\
        <Filter>*</Filter>\
        <StartingIndex>\(max(0, startIndex))</StartingIndex>\
        <RequestedCount>\(max(0, requestedCount))</RequestedCount>\
        <SortCriteria></SortCriteria>\
        </u:Browse>\
        </s:Body>\
        </s:Envelope>
        """
        return Data(body.utf8)
    }

    static func validate(
        response: HTTPURLResponse,
        data: Data
    ) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw SourceAdapterError.unauthorized
        case 404:
            throw SourceAdapterError.notFound(
                response.url?.absoluteString ?? "UPnP control URL"
            )
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SourceAdapterError.transport(
                "HTTP \(response.statusCode): \(body.prefix(300))"
            )
        }
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Config & registry

/// Tuning for ``UPnPSourceAdapter``.
public struct UPnPConfiguration: Sendable, Equatable {
    public var requestTimeout: TimeInterval
    public var chunkSize: Int
    public var maxDepth: Int
    public var pageSize: Int

    public init(
        requestTimeout: TimeInterval = 30,
        chunkSize: Int = 256 * 1024,
        maxDepth: Int = 16,
        pageSize: Int = 200
    ) {
        self.requestTimeout = max(1, requestTimeout)
        self.chunkSize = max(1, chunkSize)
        self.maxDepth = max(0, maxDepth)
        self.pageSize = max(1, pageSize)
    }
}

private actor UPnPSessionRegistry {
    private var clients: [UUID: UPnPContentDirectoryClient] = [:]

    func set(_ client: UPnPContentDirectoryClient, for id: UUID) {
        clients[id] = client
    }

    func client(for id: UUID) -> UPnPContentDirectoryClient? {
        clients[id]
    }

    func remove(for id: UUID) {
        clients.removeValue(forKey: id)
    }
}

// MARK: - Adapter

/// UPnP/DLNA `ContentDirectory` browser and streamer (SRC-9, doc 03 §3).
///
/// The adapter browses the server's object tree with SOAP `Browse` calls and
/// streams the advertised `res` URLs with ranged HTTP GETs. The root object id
/// defaults to `0`, and recursive enumeration follows containers.
public final class UPnPSourceAdapter: SourceAdapter, @unchecked Sendable {
    public let kind: SourceKind = .upnp
    public let configuration: UPnPConfiguration

    private let transport: any UPnPHTTPTransport
    private let registry = UPnPSessionRegistry()

    public init(
        configuration: UPnPConfiguration = UPnPConfiguration(),
        transport: any UPnPHTTPTransport = URLSessionUPnPTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    // MARK: Connection

    public func connect(config: SourceConfig) async throws -> SourceSession {
        let serviceType = config.options["serviceType"]
            ?? "urn:schemas-upnp-org:service:ContentDirectory:1"
        let controlURL: URL

        if let explicit = config.options["controlURL"],
           let url = URL(string: explicit) {
            controlURL = url
        } else {
            guard let descriptionURL = config.endpoint else {
                throw SourceAdapterError.invalidConfiguration(
                    "UPnP sources require a device description URL."
                )
            }
            var request = URLRequest(url: descriptionURL)
            request.timeoutInterval = configuration.requestTimeout
            request.setValue(
                "text/xml, application/xml",
                forHTTPHeaderField: "Accept"
            )
            let (data, response) = try await transport.send(request)
            try UPnPContentDirectoryClient.validate(
                response: response,
                data: data
            )
            let description = try UPnPDeviceDescription.parse(
                data,
                baseURL: descriptionURL
            )
            guard let service = description.contentDirectory,
                  let url = service.controlURL else {
                throw SourceAdapterError.unsupported(
                    "UPnP ContentDirectory browsing"
                )
            }
            controlURL = url
        }

        let client = UPnPContentDirectoryClient(
            controlURL: controlURL,
            serviceType: serviceType,
            transport: transport
        )
        let rootID = config.options["root"] ?? "0"
        let session = SourceSession(
            sourceID: config.id,
            capabilities: [
                .rangeRequests,
                .recursiveEnumeration,
                .directPlay
            ],
            metadata: [
                "upnp.controlURL": controlURL.absoluteString,
                "upnp.serviceType": serviceType,
                "upnp.rootID": rootID
            ]
        )
        await registry.set(client, for: session.id)
        return session
    }

    // MARK: Enumeration

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        guard let client = await registry.client(for: session.id) else {
            throw SourceAdapterError.reauthenticationRequired
        }
        let root = scope.path.isEmpty
            ? (session.metadata["upnp.rootID"] ?? "0")
            : scope.path
        let items = try await walk(
            client: client,
            root: root,
            scope: scope,
            sourceID: session.sourceID
        )

        return ItemStream { continuation in
            Task {
                for item in items {
                    if Task.isCancelled {
                        break
                    }
                    continuation.yield(item)
                }
                continuation.finish()
            }
        }
    }

    private func walk(
        client: UPnPContentDirectoryClient,
        root: String,
        scope: LibraryScope,
        sourceID: UUID
    ) async throws -> [SourceItem] {
        var items: [SourceItem] = []
        var queue: [(id: String, parent: String?, depth: Int)] = [
            (root, nil, 0)
        ]
        var visited: Set<String> = []

        while !queue.isEmpty {
            try Task.checkCancellation()
            let node = queue.removeFirst()
            guard !visited.contains(node.id) else {
                continue
            }
            visited.insert(node.id)

            var startIndex = 0
            while true {
                try Task.checkCancellation()
                let page = try await client.browse(
                    objectID: node.id,
                    startIndex: startIndex,
                    requestedCount: configuration.pageSize
                )
                for object in page.objects {
                    guard let item = makeItem(
                        object: object,
                        parentID: node.parent,
                        sourceID: sourceID
                    ) else {
                        continue
                    }
                    if object.isContainer {
                        items.append(item)
                        if scope.recursive, node.depth < configuration.maxDepth {
                            queue.append((object.id, item.id, node.depth + 1))
                        }
                        continue
                    }
                    guard SourceGlob.allows(
                        name: object.title,
                        path: item.location,
                        include: scope.includeGlobs,
                        exclude: scope.excludeGlobs
                    ) else {
                        continue
                    }
                    items.append(item)
                }

                startIndex += page.objects.count
                if page.objects.isEmpty
                    || startIndex >= page.totalMatches {
                    break
                }
            }
        }
        return items
    }

    private func makeItem(
        object: DIDLObject,
        parentID: String?,
        sourceID: UUID
    ) -> SourceItem? {
        if object.isContainer {
            return SourceItem(
                id: "\(sourceID.uuidString)-upnp-\(object.id)",
                sourceID: sourceID,
                kind: .folder,
                name: object.title.isEmpty ? object.id : object.title,
                location: object.id,
                parentID: parentID,
                modifiedAt: object.date
            )
        }

        guard let resource = object.preferredResource else {
            return nil
        }
        let extensionName = resource.url.pathExtension.lowercased()
        return SourceItem(
            id: "\(sourceID.uuidString)-upnp-\(object.id)",
            sourceID: sourceID,
            kind: object.isVideo ? .movie : .unknown,
            name: object.title.isEmpty
                ? resource.url.lastPathComponent
                : object.title,
            location: resource.url.absoluteString,
            parentID: parentID,
            sizeBytes: resource.sizeBytes,
            modifiedAt: object.date,
            etag: object.id,
            container: extensionName.isEmpty ? nil : extensionName,
            durationSeconds: resource.durationSeconds
        )
    }

    // MARK: Reads

    public func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.stream(
                        item: item,
                        range: range,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(
                        throwing: SourceAdapterError.cancelled
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func stream(
        item: SourceItem,
        range: ByteRange?,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        guard let url = URL(string: item.location) else {
            throw SourceAdapterError.notFound(item.location)
        }
        if let size = item.sizeBytes, let range, range.start >= size {
            throw SourceAdapterError.rangeNotSatisfiable(range, size: size)
        }

        var cursor = range?.start ?? 0
        let endExclusive = range?.end.map { $0 + 1 } ?? item.sizeBytes

        while true {
            try Task.checkCancellation()
            if let endExclusive, cursor >= endExclusive {
                return
            }

            let last = endExclusive.map {
                min($0 - 1, cursor + Int64(configuration.chunkSize) - 1)
            } ?? (cursor + Int64(configuration.chunkSize) - 1)
            let requested = try ByteRange(start: cursor, end: last)

            var request = URLRequest(url: url)
            request.timeoutInterval = configuration.requestTimeout
            request.setValue(
                requested.httpHeaderValue,
                forHTTPHeaderField: "Range"
            )
            request.setValue("*/*", forHTTPHeaderField: "Accept")

            let (data, response) = try await transport.send(request)
            try UPnPContentDirectoryClient.validate(
                response: response,
                data: data
            )

            let slice: Data
            if response.statusCode == 200 {
                // Some DLNA servers ignore Range and return the whole object.
                let start = Int(min(cursor, Int64(data.count)))
                let end = Int(min(last + 1, Int64(data.count)))
                guard start <= end else {
                    throw SourceAdapterError.rangeNotSatisfiable(
                        requested,
                        size: Int64(data.count)
                    )
                }
                slice = data.subdata(
                    in: (data.startIndex + start)..<(data.startIndex + end)
                )
            } else {
                slice = data
            }

            guard !slice.isEmpty else {
                return
            }
            continuation.yield(slice)
            cursor += Int64(slice.count)

            if Int64(slice.count) < (last - requested.start + 1) {
                return
            }
            if let size = item.sizeBytes, cursor >= size {
                return
            }
        }
    }

    // MARK: Session lifecycle

    public func freshness(session: SourceSession) async throws -> FreshnessInfo {
        FreshnessInfo(strategy: .none, checkedAt: Date())
    }

    public func disconnect(session: SourceSession) async {
        await registry.remove(for: session.id)
    }
}
