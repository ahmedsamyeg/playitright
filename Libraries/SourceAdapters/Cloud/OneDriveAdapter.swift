import Foundation

/// Microsoft OneDrive cloud source via Microsoft Graph (SRC-12, SRC-13, SRC-14).
public struct OneDriveAPI: CloudDriveAPI, Sendable {
    public let kind: SourceKind = .oneDrive
    public let providerName = "OneDrive"
    public let defaultRootID = "root"
    public let baseURL: URL

    public init(baseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!) {
        self.baseURL = baseURL
    }

    public func listChildren(
        folderID: String,
        pageToken: String?,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> CloudListPage {
        let url: URL
        if let pageToken, let next = URL(string: pageToken) {
            url = next
        } else {
            var components = URLComponents(
                url: baseURL
                    .appendingPathComponent("me/drive/items")
                    .appendingPathComponent(folderID)
                    .appendingPathComponent("children"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "$top", value: "200"),
                URLQueryItem(
                    name: "$select",
                    value: "id,name,size,lastModifiedDateTime,folder,file"
                )
            ]
            guard let built = components?.url else {
                throw SourceAdapterError.invalidConfiguration(
                    "Could not build the OneDrive listing URL."
                )
            }
            url = built
        }

        var request = URLRequest(url: url)
        request.setValue(
            CloudRequest.authorization(token),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.send(request)
        try CloudRequest.validate(response: response, data: data)

        let decoded: ChildrenResponse
        do {
            decoded = try JSONDecoder().decode(ChildrenResponse.self, from: data)
        } catch {
            throw SourceAdapterError.protocolViolation(
                "The OneDrive listing was malformed."
            )
        }

        return CloudListPage(
            entries: decoded.value.map { entry in
                CloudEntry(
                    id: entry.id,
                    name: entry.name,
                    isDirectory: entry.folder != nil,
                    sizeBytes: entry.folder == nil ? entry.size : nil,
                    modifiedAt: CloudRequest.iso8601(entry.lastModifiedDateTime)
                )
            },
            nextPageToken: decoded.nextLink
        )
    }

    public func read(
        fileID: String,
        range: ByteRange,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("me/drive/items")
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

    private struct ChildrenResponse: Decodable {
        let value: [Entry]
        let nextLink: String?

        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private struct Entry: Decodable {
        let id: String
        let name: String
        let size: Int64?
        let lastModifiedDateTime: String?
        let folder: Folder?
        let file: File?

        struct Folder: Decodable {}
        struct File: Decodable {}
    }
}

/// OneDrive source adapter.
public typealias OneDriveAdapter = CloudDriveCore<OneDriveAPI>
