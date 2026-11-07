import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Fixtures

private let payload = Data("0123456789ABCDEFGHIJ".utf8)

private let didlXML = """
<?xml version="1.0" encoding="utf-8"?>
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
xmlns:dc="http://purl.org/dc/elements/1.1/" \
xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
  <container id="1" parentID="0" restricted="1">
    <dc:title>Movies &amp; Shows</dc:title>
    <upnp:class>object.container.storageFolder</upnp:class>
  </container>
  <item id="2" parentID="1" restricted="1">
    <dc:title>Big Buck Bunny</dc:title>
    <upnp:class>object.item.videoItem.movie</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:*" size="12345" \
duration="0:10:05.500" resolution="1920x1080">\
http://192.168.1.10:8200/media/bbb.mp4</res>
  </item>
</DIDL-Lite>
"""

private let descriptionXML = """
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>Living Room DLNA</friendlyName>
    <manufacturer>Acme</manufacturer>
    <modelName>MediaBox</modelName>
    <UDN>uuid:media-server-1</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
        <controlURL>/ctl/ContentDir</controlURL>
        <eventSubURL>/evt/ContentDir</eventSubURL>
      </service>
    </serviceList>
  </device>
</root>
"""

private func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func soapPage(
    _ didl: String,
    totalMatches: Int = 0
) -> Data {
    let escaped = xmlEscape(didl)
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
      <s:Body>
        <u:BrowseResponse \
    xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
          <Result>\(escaped)</Result>
          <NumberReturned>1</NumberReturned>
          <TotalMatches>\(totalMatches)</TotalMatches>
          <UpdateID>0</UpdateID>
        </u:BrowseResponse>
      </s:Body>
    </s:Envelope>
    """
    return Data(xml.utf8)
}

private func rootDIDL() -> String {
    """
    <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
    xmlns:dc="http://purl.org/dc/elements/1.1/" \
    xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
      <container id="1" parentID="0">
        <dc:title>Movies</dc:title>
        <upnp:class>object.container.storageFolder</upnp:class>
      </container>
      <item id="2" parentID="0">
        <dc:title>trailer.mp4</dc:title>
        <upnp:class>object.item.videoItem</upnp:class>
        <res protocolInfo="http-get:*:video/mp4:*" size="20">\
    http://192.168.1.10:8200/media/trailer.mp4</res>
      </item>
    </DIDL-Lite>
    """
}

private func movieDIDL() -> String {
    """
    <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
    xmlns:dc="http://purl.org/dc/elements/1.1/" \
    xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
      <item id="3" parentID="1">
        <dc:title>movie.mkv</dc:title>
        <upnp:class>object.item.videoItem.movie</upnp:class>
        <res protocolInfo="http-get:*:video/x-matroska:*" size="20" \
    duration="0:01:02.000">\
    http://192.168.1.10:8200/media/movie.mkv</res>
      </item>
    </DIDL-Lite>
    """
}

private actor UPnPMockTransport: UPnPHTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private let handler: Handler
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.append(request)
        let (status, data) = try handler(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/xml"]
              ) else {
            throw SourceAdapterError.protocolViolation("No response URL.")
        }
        return (data, response)
    }

    func requests() -> [URLRequest] {
        recorded
    }
}

private struct StubSSDPTransport: SSDPTransporting {
    let packets: [Data]

    func search(
        _ request: Data,
        timeout: TimeInterval
    ) async throws -> [Data] {
        packets
    }
}

private func collect<T: Sendable>(
    _ stream: AsyncThrowingStream<T, Error>
) async throws -> [T] {
    var values: [T] = []
    for try await value in stream {
        values.append(value)
    }
    return values
}

private func collectData(
    _ stream: AsyncThrowingStream<Data, Error>
) async throws -> Data {
    try await collect(stream).reduce(into: Data()) { $0.append($1) }
}

// MARK: - Tests

@Suite("UPnPAdapter Tests")
struct UPnPAdapterTests {
    @Test("SSDP advertisements parse headers, location, and max-age")
    func ssdpAdvertisementParsing() {
        let packet = """
        HTTP/1.1 200 OK\r
        CACHE-CONTROL: max-age=1800\r
        EXT:\r
        LOCATION: http://192.168.1.10:8200/description.xml\r
        SERVER: Linux/5.10 UPnP/1.0 MediaBox/1.2\r
        ST: urn:schemas-upnp-org:device:MediaServer:1\r
        USN: uuid:media-server-1::urn:schemas-upnp-org:device:MediaServer:1\r
        \r
        """
        let advertisement = SSDPAdvertisement.parse(packet)

        #expect(advertisement?.location?.path == "/description.xml")
        #expect(advertisement?.maxAge == 1_800)
        #expect(advertisement?.server?.contains("MediaBox") == true)
        #expect(
            advertisement?.searchTarget
                == "urn:schemas-upnp-org:device:MediaServer:1"
        )
        #expect(advertisement?.uniqueServiceName?.hasPrefix("uuid:") == true)

        #expect(SSDPAdvertisement.parse("garbage") == nil)
        #expect(SSDPAdvertisement.parse("HTTP/1.1 200 OK\r\n\r\n") == nil)
    }

    @Test("Discovery sends M-SEARCH and de-duplicates advertisements")
    func ssdpDiscovery() async throws {
        let first = """
        HTTP/1.1 200 OK\r
        LOCATION: http://192.168.1.10:8200/description.xml\r
        ST: urn:schemas-upnp-org:device:MediaServer:1\r
        USN: uuid:media-server-1\r
        \r
        """
        let duplicate = """
        HTTP/1.1 200 OK\r
        LOCATION: http://192.168.1.10:8200/description.xml\r
        ST: urn:schemas-upnp-org:device:MediaServer:1\r
        USN: uuid:media-server-1\r
        \r
        """
        let second = """
        HTTP/1.1 200 OK\r
        LOCATION: http://192.168.1.20:8200/description.xml\r
        ST: urn:schemas-upnp-org:device:MediaServer:1\r
        USN: uuid:media-server-2\r
        \r
        """
        let discovery = SSDPDiscovery(
            transport: StubSSDPTransport(
                packets: [
                    Data(first.utf8),
                    Data(duplicate.utf8),
                    Data(second.utf8),
                    Data("not an advert".utf8)
                ]
            )
        )
        let found = try await discovery.discover()
        #expect(found.count == 2)
        #expect(
            found.map(\.uniqueServiceName)
                == ["uuid:media-server-1", "uuid:media-server-2"]
        )

        let request = String(
            data: SSDPDiscovery.searchRequest(
                mx: 2,
                searchTarget: "urn:schemas-upnp-org:device:MediaServer:1"
            ),
            encoding: .utf8
        ) ?? ""
        #expect(request.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        #expect(request.contains("HOST: 239.255.255.250:1900"))
        #expect(request.contains("MAN: \"ssdp:discover\""))
        #expect(request.contains("MX: 2"))
        #expect(
            request.contains("ST: urn:schemas-upnp-org:device:MediaServer:1")
        )
    }

    @Test("DIDL-Lite parses containers, items, and resource metadata")
    func didlParsing() throws {
        let lite = try DIDLLite.parse(Data(didlXML.utf8))

        #expect(lite.objects.count == 2)
        #expect(lite.containers.count == 1)
        #expect(lite.items.count == 1)

        let container = try #require(lite.containers.first)
        #expect(container.id == "1")
        #expect(container.parentID == "0")
        #expect(container.title == "Movies & Shows")
        #expect(container.upnpClass == "object.container.storageFolder")

        let item = try #require(lite.items.first)
        #expect(item.id == "2")
        #expect(item.title == "Big Buck Bunny")
        #expect(item.isVideo)
        let resource = try #require(item.preferredResource)
        #expect(resource.url.absoluteString
            == "http://192.168.1.10:8200/media/bbb.mp4")
        #expect(resource.sizeBytes == 12_345)
        #expect(resource.durationSeconds == 605.5)
        #expect(resource.resolution == "1920x1080")
        #expect(resource.protocolInfo == "http-get:*:video/mp4:*")
    }

    @Test("SOAP Browse responses expose escaped DIDL-Lite metadata")
    func soapResponseParsing() throws {
        let page = try UPnPBrowsePage.parse(
            soapPage(didlXML, totalMatches: 2)
        )
        #expect(page.totalMatches == 2)
        #expect(page.numberReturned == 1)
        #expect(page.objects.count == 2)
        #expect(page.objects[0].title == "Movies & Shows")

        let empty = try UPnPBrowsePage.parse(
            soapPage("", totalMatches: 0)
        )
        #expect(empty.objects.isEmpty)
        #expect(empty.totalMatches == 0)
    }

    @Test("The Browse envelope escapes ids and carries paging fields")
    func soapEnvelope() throws {
        let data = UPnPContentDirectoryClient.browseEnvelope(
            objectID: "Movies & Shows<1>",
            browseFlag: "BrowseDirectChildren",
            startIndex: 10,
            requestedCount: 25
        )
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(
            text.contains(
                "<ObjectID>Movies &amp; Shows&lt;1&gt;</ObjectID>"
            )
        )
        #expect(text.contains("<StartingIndex>10</StartingIndex>"))
        #expect(text.contains("<RequestedCount>25</RequestedCount>"))
        #expect(
            text.contains(
                "<BrowseFlag>BrowseDirectChildren</BrowseFlag>"
            )
        )
    }

    @Test("Device descriptions resolve the ContentDirectory control URL")
    func deviceDescription() throws {
        let base = URL(string: "http://192.168.1.10:8200/description.xml")!
        let description = try UPnPDeviceDescription.parse(
            Data(descriptionXML.utf8),
            baseURL: base
        )

        #expect(description.friendlyName == "Living Room DLNA")
        #expect(description.manufacturer == "Acme")
        #expect(description.modelName == "MediaBox")
        #expect(description.udn == "uuid:media-server-1")
        #expect(description.services.count == 1)

        let service = try #require(description.contentDirectory)
        #expect(
            service.serviceType
                == "urn:schemas-upnp-org:service:ContentDirectory:1"
        )
        #expect(
            service.controlURL?.absoluteString
                == "http://192.168.1.10:8200/ctl/ContentDir"
        )
        #expect(
            service.eventSubURL?.absoluteString
                == "http://192.168.1.10:8200/evt/ContentDir"
        )
    }

    @Test("The adapter browses folders and streams ranged resources")
    func adapterBrowseAndRead() async throws {
        let transport = UPnPMockTransport { request in
            let url = request.url?.absoluteString ?? ""

            if url.hasSuffix("/description.xml") {
                return (200, Data(descriptionXML.utf8))
            }
            if url.contains("/media/") {
                guard let header = request.value(
                    forHTTPHeaderField: "Range"
                ), let range = ByteRange(httpHeaderValue: header),
                      let clamped = range.clamped(to: Int64(payload.count)) else {
                    return (200, payload)
                }
                let start = Int(clamped.start)
                let end = Int(clamped.end ?? (Int64(payload.count) - 1))
                return (
                    206,
                    payload.subdata(in: start..<(end + 1))
                )
            }

            let body = String(
                data: request.httpBody ?? Data(),
                encoding: .utf8
            ) ?? ""
            if body.contains("<ObjectID>1</ObjectID>") {
                return (200, soapPage(movieDIDL(), totalMatches: 1))
            }
            return (200, soapPage(rootDIDL(), totalMatches: 2))
        }

        let adapter = UPnPSourceAdapter(
            configuration: UPnPConfiguration(
                chunkSize: 4,
                pageSize: 50
            ),
            transport: transport
        )
        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .upnp,
                name: "DLNA",
                endpoint: URL(string: "http://192.168.1.10:8200/description.xml")
            )
        )
        #expect(adapter.kind == .upnp)
        #expect(
            session.metadata["upnp.controlURL"]
                == "http://192.168.1.10:8200/ctl/ContentDir"
        )
        #expect(session.metadata["upnp.rootID"] == "0")
        #expect(session.capabilities.contains(.rangeRequests))

        let items = try await collect(
            adapter.enumerate(session: session, scope: LibraryScope())
        )
        #expect(items.count == 3)
        let folder = try #require(
            items.first { $0.name == "Movies" }
        )
        #expect(folder.kind == .folder)
        #expect(folder.location == "1")

        let movie = try #require(
            items.first { $0.name == "movie.mkv" }
        )
        #expect(movie.kind == .movie)
        #expect(movie.container == "mkv")
        #expect(movie.sizeBytes == 20)
        #expect(movie.durationSeconds == 62)
        #expect(movie.parentID == folder.id)

        let range = try ByteRange(start: 5, end: 9)
        let data = try await collectData(
            adapter.read(session: session, item: movie, range: range)
        )
        #expect(data == Data("56789".utf8))

        let tailRange = try ByteRange(start: 15, end: nil)
        let tail = try await collectData(
            adapter.read(session: session, item: movie, range: tailRange)
        )
        #expect(tail == Data("FGHIJ".utf8))

        let requests = await transport.requests()
        let rangeRequests = requests.filter {
            $0.url?.absoluteString.contains("/media/") == true
        }
        #expect(!rangeRequests.isEmpty)
        #expect(
            rangeRequests.allSatisfy {
                $0.value(forHTTPHeaderField: "Range") != nil
            }
        )
    }

    @Test("Non-recursive UPnP enumeration stops at the first level")
    func nonRecursiveBrowse() async throws {
        let transport = UPnPMockTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/description.xml") {
                return (200, Data(descriptionXML.utf8))
            }
            return (200, soapPage(rootDIDL(), totalMatches: 2))
        }
        let adapter = UPnPSourceAdapter(transport: transport)
        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .upnp,
                name: "DLNA",
                endpoint: URL(string: "http://192.168.1.10:8200/description.xml")
            )
        )
        let items = try await collect(
            adapter.enumerate(
                session: session,
                scope: LibraryScope(recursive: false)
            )
        )
        #expect(items.count == 2)
        #expect(items.contains { $0.name == "trailer.mp4" })
        #expect(!items.contains { $0.name == "movie.mkv" })

        let filtered = try await collect(
            adapter.enumerate(
                session: session,
                scope: LibraryScope(
                    recursive: false,
                    includeGlobs: ["*.mkv"]
                )
            )
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.kind == .folder)
        #expect(!filtered.contains { $0.name == "trailer.mp4" })
    }

    @Test("Explicit control URLs skip the device description fetch")
    func explicitControlURL() async throws {
        let transport = UPnPMockTransport { _ in
            (200, soapPage(rootDIDL(), totalMatches: 2))
        }
        let adapter = UPnPSourceAdapter(transport: transport)
        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .upnp,
                name: "DLNA",
                options: [
                    "controlURL": "http://192.168.1.10:8200/ctl/ContentDir",
                    "root": "1"
                ]
            )
        )
        #expect(
            session.metadata["upnp.controlURL"]
                == "http://192.168.1.10:8200/ctl/ContentDir"
        )
        #expect(session.metadata["upnp.rootID"] == "1")

        let items = try await collect(
            adapter.enumerate(session: session, scope: LibraryScope())
        )
        #expect(items.count == 2)

        let requests = await transport.requests()
        #expect(
            requests.allSatisfy {
                $0.url?.absoluteString.contains("ContentDir") == true
            }
        )
    }
}
