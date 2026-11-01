import Foundation

/// Emby source adapter.
///
/// Emby exposes the same REST API as Jellyfin, so this adapter reuses
/// ``JellyfinSourceAdapter`` and only changes the reported ``SourceKind``.
/// This keeps a single wire-protocol implementation inside the adapters layer
/// (SRC-1).
public final class EmbySourceAdapter: JellyfinSourceAdapter {
    public init(
        configuration: JellyfinConfiguration = JellyfinConfiguration(),
        sessionConfiguration: URLSessionConfiguration? = nil,
        tokenProvider: TokenProvider? = nil,
        httpConfiguration: HTTPSourceConfiguration? = nil
    ) {
        super.init(
            brand: .emby,
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            tokenProvider: tokenProvider,
            httpConfiguration: httpConfiguration
        )
    }
}
