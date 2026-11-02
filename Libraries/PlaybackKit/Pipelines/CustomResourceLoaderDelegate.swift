import AVFoundation
import Foundation
import SourceAdapters

/// One resource request the loader has to answer.
///
/// `AVAssetResourceLoadingRequest` cannot be constructed in tests, so the
/// delegate talks to this small interface. The production adapter wraps the
/// AVFoundation object; tests supply a recording mock.
public protocol PlaybackResourceLoadingRequest: AnyObject, Sendable {
    /// First byte AVFoundation wants.
    var requestedOffset: Int64 { get }

    /// Number of bytes requested, or `0` when the length is unknown.
    var requestedLength: Int { get }

    /// Offset of the next byte the request still needs, when AVFoundation
    /// reports one. Used when a request is re-issued after a range response.
    var currentOffset: Int64 { get }

    /// Whether the request is open-ended.
    var requestsAllDataToEndOfResource: Bool { get }

    /// Whether AVFoundation also asked for content information.
    var hasContentInformationRequest: Bool { get }

    /// Whether AVFoundation has cancelled the request.
    var isCancelled: Bool { get }

    /// Stable identity for the underlying request. Adapters wrapping a
    /// platform object must return that object's identity so a later
    /// cancellation can find the in-flight read.
    var requestIdentity: ObjectIdentifier { get }

    /// Fills the content information request, when one was made.
    func setContentInformation(
        contentType: String?,
        contentLength: Int64,
        byteRangeAccessSupported: Bool
    )

    /// Delivers a chunk of bytes to AVFoundation.
    func respond(data: Data)

    /// Completes the request successfully.
    func finishLoading()

    /// Completes the request with a failure.
    func finishLoading(with error: Error)
}

// MARK: - AVFoundation adapter

/// Bridges an `AVAssetResourceLoadingRequest` to ``PlaybackResourceLoadingRequest``.
final class AVPlaybackResourceLoadingRequest: PlaybackResourceLoadingRequest, @unchecked Sendable {
    private let request: AVAssetResourceLoadingRequest

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }

    var requestedOffset: Int64 {
        request.dataRequest?.requestedOffset ?? 0
    }

    var requestedLength: Int {
        request.dataRequest?.requestedLength ?? 0
    }

    var currentOffset: Int64 {
        request.dataRequest?.currentOffset ?? 0
    }

    var requestsAllDataToEndOfResource: Bool {
        request.dataRequest?.requestsAllDataToEndOfResource ?? false
    }

    var hasContentInformationRequest: Bool {
        request.contentInformationRequest != nil
    }

    var isCancelled: Bool {
        request.isCancelled
    }

    var requestIdentity: ObjectIdentifier {
        ObjectIdentifier(request)
    }

    func setContentInformation(
        contentType: String?,
        contentLength: Int64,
        byteRangeAccessSupported: Bool
    ) {
        guard let contentInformation = request.contentInformationRequest else {
            return
        }
        if let contentType {
            contentInformation.contentType = contentType
        }
        contentInformation.contentLength = contentLength
        contentInformation.isByteRangeAccessSupported = byteRangeAccessSupported
    }

    func respond(data: Data) {
        request.dataRequest?.respond(with: data)
    }

    func finishLoading() {
        request.finishLoading()
    }

    func finishLoading(with error: Error) {
        request.finishLoading(with: error)
    }
}

// MARK: - Delegate

/// Serves AVFoundation byte-range requests from a ``SourceAdapter`` stream
/// (PB-G2, doc 04 §4.2).
///
/// AVFoundation loads a custom-scheme asset through this delegate. Every data
/// request is translated into a ``ByteRange`` and fed from
/// `SourceAdapter.read(session:item:range:)`. Cancelled requests — including
/// the request a seek supersedes — stop their source stream immediately.
public final class CustomResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// Scheme used for source-backed assets.
    public static let scheme = "playitright"

    /// The source backing the asset.
    public let adapter: any SourceAdapter
    public let session: SourceSession
    public let item: SourceItem

    /// Total size in bytes when known. Required for open-ended ranges.
    public let contentLength: Int64?

    /// UTI or MIME type AVFoundation should be told about.
    public let contentType: String

    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var cancelledRequests: Set<ObjectIdentifier> = []

    /// A queue for AVFoundation resource-loader callbacks. Serial so the
    /// AVFoundation request objects are only touched from one thread.
    public let queue: DispatchQueue

    public init(
        adapter: any SourceAdapter,
        session: SourceSession,
        item: SourceItem,
        contentLength: Int64? = nil,
        contentType: String? = nil,
        queue: DispatchQueue = DispatchQueue(
            label: "com.playitright.resource-loader"
        )
    ) {
        self.adapter = adapter
        self.session = session
        self.item = item
        self.contentLength = contentLength ?? item.sizeBytes
        self.contentType = contentType ?? Self.contentType(for: item)
        self.queue = queue
        super.init()
    }

    /// The custom URL AVFoundation uses for this item.
    public func assetURL() -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "source"
        components.path = "/" + Self.sanitizedPath(item)
        return components.url
            ?? URL(string: "\(Self.scheme)://source/item")!
    }

    /// Builds an `AVURLAsset` wired to this delegate.
    public func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: assetURL())
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Number of source reads currently in flight.
    public var activeRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    /// Whether the request with this identity was cancelled.
    public func wasCancelled(_ request: any PlaybackResourceLoadingRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledRequests.contains(request.requestIdentity)
    }

    // MARK: - Core handling (testable)

    /// Answers a resource request. Exposed for unit tests.
    public func handle(_ request: any PlaybackResourceLoadingRequest) {
        if request.hasContentInformationRequest, let contentLength {
            request.setContentInformation(
                contentType: contentType,
                contentLength: contentLength,
                byteRangeAccessSupported: true
            )
        }

        let offset = max(
            0,
            request.currentOffset > 0
                ? request.currentOffset
                : request.requestedOffset
        )
        let end = Self.rangeEnd(
            request: request,
            offset: offset,
            contentLength: contentLength
        )

        // A pure content-information request has no data request.
        if request.requestedLength == 0,
           !request.requestsAllDataToEndOfResource,
           offset == 0 {
            request.finishLoading()
            return
        }

        let range: ByteRange?
        do {
            range = try ByteRange(start: offset, end: end)
        } catch {
            request.finishLoading(with: error)
            return
        }

        let key = request.requestIdentity
        let task = Task { [adapter, session, item, contentLength] in
            var delivered: Int64 = 0
            let expected = range?.length

            do {
                for try await chunk in adapter.read(
                    session: session,
                    item: item,
                    range: range
                ) {
                    if Task.isCancelled || request.isCancelled {
                        break
                    }
                    request.respond(data: chunk)
                    delivered += Int64(chunk.count)

                    if let expected, delivered >= expected {
                        break
                    }
                    if let contentLength, offset + delivered >= contentLength {
                        break
                    }
                }

                if request.isCancelled || Task.isCancelled {
                    request.finishLoading(with: CancellationError())
                } else {
                    request.finishLoading()
                }
            } catch {
                if request.isCancelled || Task.isCancelled {
                    request.finishLoading(with: CancellationError())
                } else {
                    request.finishLoading(with: error)
                }
            }

            self.removeTask(for: key)
        }

        lock.lock()
        cancelledRequests.remove(key)
        tasks[key] = task
        lock.unlock()
    }

    /// Cancels an in-flight request. Called by AVFoundation when a seek or
    /// teardown supersedes the request.
    public func cancel(_ request: any PlaybackResourceLoadingRequest) {
        let key = request.requestIdentity
        lock.lock()
        cancelledRequests.insert(key)
        let task = tasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitFor loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        handle(AVPlaybackResourceLoadingRequest(loadingRequest))
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let wrapped = AVPlaybackResourceLoadingRequest(loadingRequest)
        cancel(wrapped)
    }

    // MARK: - Helpers

    private func removeTask(for key: ObjectIdentifier) {
        lock.lock()
        tasks.removeValue(forKey: key)
        lock.unlock()
    }

    private static func rangeEnd(
        request: any PlaybackResourceLoadingRequest,
        offset: Int64,
        contentLength: Int64?
    ) -> Int64? {
        if request.requestsAllDataToEndOfResource {
            return contentLength.map { max($0 - 1, offset) }
        }
        guard request.requestedLength > 0 else {
            return contentLength.map { max($0 - 1, offset) }
        }
        return offset + Int64(request.requestedLength) - 1
    }

    /// Maps a source item to the content type AVFoundation expects.
    public static func contentType(for item: SourceItem) -> String {
        let container = (item.container ?? URL(
            fileURLWithPath: item.location
        ).pathExtension).lowercased()
        switch container {
        case "mp4", "m4v":
            return "public.mpeg-4"
        case "mov":
            return "com.apple.quicktime-movie"
        case "ts", "m2ts", "mts":
            return "public.mpeg-2-transport-stream"
        case "mkv":
            return "org.matroska.mkv"
        case "webm":
            return "org.webmproject.webm"
        case "avi":
            return "public.avi"
        case "mp3":
            return "public.mp3"
        default:
            return "public.data"
        }
    }

    private static func sanitizedPath(_ item: SourceItem) -> String {
        let name = item.name.isEmpty ? item.id : item.name
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        return name.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? "item"
    }
}
