import Foundation

/// Dropbox cloud source (SRC-12, SRC-13, SRC-14).
public struct DropboxAPI: CloudDriveAPI, Sendable {
    public let kind: SourceKind = .dropbox
    public let providerName = "Dropbox"
    public let defaultRootID = ""

    public let apiBaseURL: URL
    public let contentBaseURL: URL

    public init(
        apiBaseURL: URL = URL(string: "https://api.dropboxapi.com/2")!,
        contentBaseURL: URL = URL(string: "https://content.dropboxapi.com/2")!
    ) {
        self.apiBaseURL = apiBaseURL
        self.contentBaseURL = contentBaseURL
    }

    public func listChildren(
        folderID: String,
        pageToken: String?,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> CloudListPage {
        let path: String
        let body: Data
        if let pageToken {
            path = "files/list_folder/continue"
            body = try JSONSerialization.data(
                withJSONObject: ["cursor": pageToken]
            )
        } else {
            path = "files/list_folder"
            body = try JSONSerialization.data(
                withJSONObject: [
                    "path": folderID,
                    "recursive": false,
                    "limit": 2_000
                ]
            )
        }

        var request = URLRequest(
            url: apiBaseURL.appendingPathComponent(path)
        )
        request.httpMethod = "POST"
        request.setValue(
            CloudRequest.authorization(token),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let (data, response) = try await transport.send(request)
        try CloudRequest.validate(response: response, data: data)

        let decoded: ListFolderResponse
        do {
            decoded = try JSONDecoder().decode(ListFolderResponse.self, from: data)
        } catch {
            throw SourceAdapterError.protocolViolation(
                "The Dropbox listing was malformed."
            )
        }

        return CloudListPage(
            entries: decoded.entries.map { entry in
                let isDirectory = entry.tag == "folder"
                let id = entry.pathLower
                    ?? entry.pathDisplay
                    ?? entry.id
                    ?? entry.name
                return CloudEntry(
                    id: id,
                    name: entry.name,
                    isDirectory: isDirectory,
                    sizeBytes: isDirectory ? nil : entry.size,
                    modifiedAt: CloudRequest.iso8601(entry.serverModified)
                )
            },
            nextPageToken: decoded.hasMore ? decoded.cursor : nil
        )
    }

    public func read(
        fileID: String,
        range: ByteRange,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> Data {
        var request = URLRequest(
            url: contentBaseURL.appendingPathComponent("files/download")
        )
        request.httpMethod = "POST"
        request.setValue(
            CloudRequest.authorization(token),
            forHTTPHeaderField: "Authorization"
        )
        let argument = try JSONSerialization.data(
            withJSONObject: ["path": fileID]
        )
        request.setValue(
            String(data: argument, encoding: .utf8),
            forHTTPHeaderField: "Dropbox-API-Arg"
        )
        request.setValue(
            range.httpHeaderValue,
            forHTTPHeaderField: "Range"
        )
        request.setValue("", forHTTPHeaderField: "Content-Type")
        return try await CloudRequest.rangedData(
            request,
            range: range,
            transport: transport
        )
    }

    private struct ListFolderResponse: Decodable {
        let entries: [Entry]
        let cursor: String
        let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case entries
            case cursor
            case hasMore = "has_more"
        }
    }

    private struct Entry: Decodable {
        let tag: String
        let name: String
        let id: String?
        let pathLower: String?
        let pathDisplay: String?
        let size: Int64?
        let serverModified: String?

        enum CodingKeys: String, CodingKey {
            case tag = ".tag"
            case name
            case id
            case pathLower = "path_lower"
            case pathDisplay = "path_display"
            case size
            case serverModified = "server_modified"
        }
    }
}

/// Dropbox source adapter.
public typealias DropboxAdapter = CloudDriveCore<DropboxAPI>
