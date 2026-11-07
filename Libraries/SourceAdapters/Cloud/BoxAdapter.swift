import Foundation

/// Box cloud source (SRC-12, SRC-13, SRC-14).
public struct BoxAPI: CloudDriveAPI, Sendable {
    public let kind: SourceKind = .box
    public let providerName = "Box"
    public let defaultRootID = "0"
    public let baseURL: URL

    public init(baseURL: URL = URL(string: "https://api.box.com/2.0")!) {
        self.baseURL = baseURL
    }

    public func listChildren(
        folderID: String,
        pageToken: String?,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> CloudListPage {
        let offset = Int(pageToken ?? "0") ?? 0
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("folders")
                .appendingPathComponent(folderID)
                .appendingPathComponent("items"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "limit", value: "1_000"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(
                name: "fields",
                value: "id,type,name,size,modified_at"
            )
        ]
        guard let url = components?.url else {
            throw SourceAdapterError.invalidConfiguration(
                "Could not build the Box listing URL."
            )
        }

        var request = URLRequest(url: url)
        request.setValue(
            CloudRequest.authorization(token),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.send(request)
        try CloudRequest.validate(response: response, data: data)

        let decoded: FolderItems
        do {
            decoded = try JSONDecoder().decode(FolderItems.self, from: data)
        } catch {
            throw SourceAdapterError.protocolViolation(
                "The Box listing was malformed."
            )
        }

        let nextOffset = offset + decoded.entries.count
        let nextToken = nextOffset < decoded.totalCount
            ? String(nextOffset)
            : nil

        return CloudListPage(
            entries: decoded.entries.map { entry in
                CloudEntry(
                    id: entry.id,
                    name: entry.name,
                    isDirectory: entry.type == "folder",
                    sizeBytes: entry.type == "folder" ? nil : entry.size,
                    modifiedAt: CloudRequest.iso8601(entry.modifiedAt)
                )
            },
            nextPageToken: nextToken
        )
    }

    public func read(
        fileID: String,
        range: ByteRange,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("files")
            .appendingPathComponent(fileID)
            .appendingPathComponent("content")
        var request = URLRequest(url: url)
        request.setValue(
            CloudRequest.authorization(token),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            range.httpHeaderValue,
            forHTTPHeaderField: "Range"
        )
        return try await CloudRequest.rangedData(
            request,
            range: range,
            transport: transport
        )
    }

    private struct FolderItems: Decodable {
        let entries: [Entry]
        let totalCount: Int

        enum CodingKeys: String, CodingKey {
            case entries
            case totalCount = "total_count"
        }
    }

    private struct Entry: Decodable {
        let id: String
        let type: String
        let name: String
        let size: Int64?
        let modifiedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case name
            case size
            case modifiedAt = "modified_at"
        }
    }
}

/// Box source adapter.
public typealias BoxAdapter = CloudDriveCore<BoxAPI>
