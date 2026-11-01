import Foundation

/// Errors raised while parsing a WebDAV `multistatus` document.
public enum WebDAVXMLError: Error, Equatable, Sendable, LocalizedError {
    /// The XML could not be parsed.
    case invalidXML(String)

    /// The document was not a DAV multistatus response.
    case notMultistatus

    public var errorDescription: String? {
        switch self {
        case .invalidXML(let message):
            return "Could not parse the WebDAV XML response: \(message)"
        case .notMultistatus:
            return "The response was not a WebDAV multistatus document."
        }
    }
}

/// One resource from a WebDAV `PROPFIND` response.
public struct WebDAVResource: Sendable, Equatable {
    /// The `D:href` value exactly as returned by the server.
    public var href: String

    /// Human-readable name from `D:displayname`.
    public var displayName: String?

    /// Size from `D:getcontentlength`.
    public var contentLength: Int64?

    /// MIME type from `D:getcontenttype`.
    public var contentType: String?

    /// Modification date from `D:getlastmodified`.
    public var lastModified: Date?

    /// Validator from `D:getetag`.
    public var etag: String?

    /// Whether `D:resourcetype` contained `D:collection`.
    public var isCollection: Bool

    public init(
        href: String,
        displayName: String? = nil,
        contentLength: Int64? = nil,
        contentType: String? = nil,
        lastModified: Date? = nil,
        etag: String? = nil,
        isCollection: Bool = false
    ) {
        self.href = href
        self.displayName = displayName
        self.contentLength = contentLength
        self.contentType = contentType
        self.lastModified = lastModified
        self.etag = etag
        self.isCollection = isCollection
    }
}

/// Parses a WebDAV `207 Multi-Status` `PROPFIND` response.
///
/// Namespace prefixes are stripped before matching, so `D:`, `d:`, and default
/// DAV namespaces all work.
public struct WebDAVXMLParser: Sendable {
    public init() {}

    /// Parses multistatus bytes.
    public func parse(data: Data) throws -> [WebDAVResource] {
        guard !data.isEmpty else {
            throw WebDAVXMLError.invalidXML("The response body was empty.")
        }

        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false

        let builder = WebDAVTreeBuilder()
        parser.delegate = builder

        guard parser.parse(), let root = builder.root else {
            let message = parser.parserError?.localizedDescription
                ?? "unknown XML error"
            throw WebDAVXMLError.invalidXML(message)
        }

        guard root.localName == "multistatus" else {
            throw WebDAVXMLError.notMultistatus
        }

        let responseNodes = root.children.filter {
            $0.localName == "response"
        }
        return responseNodes.compactMap(Self.resource(from:))
    }

    private static func resource(
        from node: WebDAVTreeNode
    ) -> WebDAVResource? {
        let href = node.children
            .first { $0.localName == "href" }?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let href, !href.isEmpty else {
            return nil
        }

        var displayName: String?
        var contentLength: Int64?
        var contentType: String?
        var lastModified: Date?
        var etag: String?
        var isCollection = false

        for propstat in node.children where propstat.localName == "propstat" {
            guard let prop = propstat.children.first(where: {
                $0.localName == "prop"
            }) else {
                continue
            }

            for child in prop.children {
                let text = child.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                switch child.localName {
                case "displayname":
                    if !text.isEmpty {
                        displayName = text
                    }
                case "getcontentlength":
                    contentLength = Int64(text)
                case "getcontenttype":
                    if !text.isEmpty {
                        contentType = text
                    }
                case "getlastmodified":
                    lastModified = WebDAVDateParser.date(from: text)
                case "getetag":
                    if !text.isEmpty {
                        etag = text
                    }
                case "resourcetype":
                    isCollection = child.children.contains {
                        $0.localName == "collection"
                    }
                default:
                    break
                }
            }
        }

        return WebDAVResource(
            href: href,
            displayName: displayName,
            contentLength: contentLength,
            contentType: contentType,
            lastModified: lastModified,
            etag: etag,
            isCollection: isCollection
        )
    }
}

/// Parses the HTTP date format used by WebDAV (`getlastmodified`).
public enum WebDAVDateParser {
    /// Parses RFC 1123 and the common RFC 850 variants.
    public static func date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}

// MARK: - XML tree

private final class WebDAVTreeNode {
    let name: String
    let attributes: [String: String]
    var children: [WebDAVTreeNode] = []
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Element name without its namespace prefix.
    var localName: String {
        String(name.split(separator: ":").last ?? Substring(name))
    }
}

private final class WebDAVTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: WebDAVTreeNode?
    private var stack: [WebDAVTreeNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = WebDAVTreeNode(
            name: elementName,
            attributes: attributeDict
        )
        if let parent = stack.last {
            parent.children.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty {
            stack.removeLast()
        }
    }
}
