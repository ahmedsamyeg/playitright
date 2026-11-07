import Foundation

/// Google Drive v3 cloud source (SRC-12, SRC-13, SRC-14).
public struct GoogleDriveAPI: CloudDriveAPI, Sendable {
    public let kind: SourceKind = .googleDrive
    public let providerName = "Google Drive"
    public let defaultRootID = "root"
    public let baseURL: URL

    public init(baseURL: URL = URL(string: "https://www.googleapis.com/drive/v3")!) {
        self.baseURL = baseURL
    }

    public func listChildren(
        folderID: String,
        pageToken: String?,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> CloudListPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("files"),
            resolvingAgainstBaseURL: false
        )
        var query = [
            URLQueryItem(
                name: "q",
                value: "'\(folderID)' in parents and trashed = false"
            ),
            URLQueryItem(
                name: "fields",
                value: "files(id,name,mimeType,size,modifiedTime),nextPageToken"
            ),
            URLQueryItem(name: "pageSize", value: "1000")
        ]
        if let pageToken {
            query.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components?.queryItems = query

        guard let url = components?.url else {
            throw SourceAdapterError.invalidConfiguration(
                "Could not build the Google Drive listing URL."
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            CloudRequest.authorization(token),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.send(request)
        try CloudRequest.validate(response: response, data: data)

        let decoded: FileList
        do {
            decoded = try JSONDecoder().decode(FileList.self, from: data)
        } catch {
            throw SourceAdapterError.protocolViolation(
                "The Google Drive listing was malformed."
            )
        }

        return CloudListPage(
            entries: decoded.files.map { file in
                CloudEntry(
                    id: file.id,
                    name: file.name,
                    isDirectory: file.mimeType
                        == "application/vnd.google-apps.folder",
                    sizeBytes: CloudRequest.int64(file.size),
                    modifiedAt: CloudRequest.iso8601(file.modifiedTime)
                )
            },
            nextPageToken: decoded.nextPageToken
        )
    }

    public func read(
        fileID: String,
        range: ByteRange,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("files")
                .appendingPathComponent(fileID),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "alt", value: "media")
        ]
        guard let url = components?.url else {
            throw SourceAdapterError.invalidConfiguration(
                "Could not build the Google Drive download URL."
            )
        }
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

    private struct FileList: Decodable {
        let files: [File]
        let nextPageToken: String?

        struct File: Decodable {
            let id: String
            let name: String
            let mimeType: String?
            let size: String?
            let modifiedTime: String?
        }
    }
}

/// Google Drive source adapter.
public typealias GoogleDriveAdapter = CloudDriveCore<GoogleDriveAPI>
