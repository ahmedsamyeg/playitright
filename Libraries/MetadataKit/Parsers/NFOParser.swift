import Foundation

/// Parses Kodi/Emby style `.nfo` XML files and simple sidecar text files.
///
/// Parsing never throws: malformed XML falls back to a tag-level scan so a
/// single unescaped character cannot make an otherwise useful file disappear.
public struct NFOParser: Sendable {
    public init() {}

    /// Reads and parses a `.nfo`, `.txt`, or `.read.txt` file.
    public func parse(contentsOf url: URL) -> NFOMedia? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        if ext == "nfo" {
            return parse(data)
        }
        if let text = String(data: data, encoding: .utf8) {
            return parse(text: text)
        }
        return parse(data)
    }

    /// Parses raw NFO data.
    public func parse(_ data: Data) -> NFOMedia? {
        guard !data.isEmpty else {
            return nil
        }

        if let root = parseTree(data), let media = parse(root: root) {
            return media
        }

        return parseLeniently(data)
    }

    /// Parses an XML string.
    public func parse(xml: String) -> NFOMedia? {
        parse(Data(xml.utf8))
    }

    /// Parses XML or a sidecar text file, choosing based on the first non-space
    /// character.
    public func parse(text: String) -> NFOMedia? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("<") {
            return parse(Data(text.utf8))
        }
        return parseSidecar(text: text)
    }

    /// Parses a plain-text sidecar whose first meaningful line is a title,
    /// optionally followed by a release year.
    public func parseSidecar(text: String) -> NFOMedia? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard var title = lines.first else {
            return nil
        }

        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst("title:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var year: Int?
        if let match = firstMatch(#"[\(\[]?\s*((?:19|20)\d{2})\s*[\)\]]?\s*$"#, in: title),
           let parsedYear = Int(match.value) {
            year = parsedYear
            title.removeSubrange(match.range)
        }

        title = title.trimmingCharacters(
            in: CharacterSet(charactersIn: " -–—_.:,;[](){}")
        )
        guard !title.isEmpty else {
            return nil
        }

        return NFOMedia(kind: .movie, title: title, year: year)
    }

    // MARK: - Tree parsing

    private func parseTree(_ data: Data) -> XMLTreeNode? {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false

        let builder = XMLTreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            return nil
        }
        return root
    }

    private func parse(root: XMLTreeNode) -> NFOMedia? {
        guard let kind = kind(forRootName: root.name) else {
            return nil
        }

        let title = childText("title", in: root) ?? ""
        let aired = childText("aired", in: root) ?? childText("premiered", in: root)
        let rating = ratingAndVotes(from: root)
        let ids = providerIDs(from: root)

        return NFOMedia(
            kind: kind,
            title: title,
            originalTitle: childText("originaltitle", in: root),
            sortTitle: childText("sorttitle", in: root),
            year: childText("year", in: root).flatMap(Int.init)
                ?? aired.flatMap(yearPrefix),
            plot: childText("plot", in: root) ?? childText("outline", in: root),
            tagline: childText("tagline", in: root),
            rating: rating.value,
            votes: rating.votes,
            runtimeMinutes: childText("runtime", in: root).flatMap(leadingInt),
            mpaa: childText("mpaa", in: root),
            genres: childTexts("genre", in: root),
            directors: childTexts("director", in: root),
            cast: castMembers(from: root),
            tmdbID: ids.tmdb,
            imdbID: ids.imdb,
            tvdbID: ids.tvdb,
            season: childText("season", in: root).flatMap(Int.init),
            episode: childText("episode", in: root).flatMap(Int.init),
            absoluteEpisode: absoluteEpisode(from: root),
            aired: aired
        )
    }

    private func kind(forRootName name: String?) -> NFOMediaKind? {
        switch name?.lowercased() {
        case "movie":
            return .movie
        case "tvshow", "show", "series":
            return .tvShow
        case "episodedetails", "episode":
            return .episode
        default:
            return nil
        }
    }

    private func child(_ name: String, in node: XMLTreeNode) -> XMLTreeNode? {
        node.children.first { $0.name == name }
    }

    private func children(_ name: String, in node: XMLTreeNode) -> [XMLTreeNode] {
        node.children.filter { $0.name == name }
    }

    private func childText(_ name: String, in node: XMLTreeNode) -> String? {
        guard let child = child(name, in: node) else {
            return nil
        }
        return cleaned(child.text)
    }

    private func childTexts(_ name: String, in node: XMLTreeNode) -> [String] {
        children(name, in: node).compactMap { cleaned($0.text) }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ratingAndVotes(from root: XMLTreeNode) -> (value: Double?, votes: Int?) {
        if let ratingText = childText("rating", in: root),
           let value = Double(ratingText) {
            return (value, childText("votes", in: root).flatMap(leadingInt))
        }

        if let ratings = child("ratings", in: root),
           let rating = child("rating", in: ratings) {
            return (
                childText("value", in: rating).flatMap(Double.init),
                childText("votes", in: rating).flatMap(leadingInt)
            )
        }

        return (nil, nil)
    }

    private func castMembers(from root: XMLTreeNode) -> [NFOCastMember] {
        children("actor", in: root).compactMap { actor in
            guard let name = childText("name", in: actor) else {
                return nil
            }
            return NFOCastMember(
                name: name,
                role: childText("role", in: actor),
                order: childText("order", in: actor).flatMap(Int.init),
                imageURL: childText("thumb", in: actor) ?? childText("image", in: actor)
            )
        }
    }

    private func absoluteEpisode(from root: XMLTreeNode) -> Int? {
        childText("absoluteepisode", in: root).flatMap(Int.init)
            ?? childText("absolute_episode", in: root).flatMap(Int.init)
            ?? childText("absoluteepisodenumber", in: root).flatMap(Int.init)
    }

    private func providerIDs(
        from root: XMLTreeNode
    ) -> (tmdb: Int?, imdb: String?, tvdb: Int?) {
        var tmdb: Int?
        var imdb: String?
        var tvdb: Int?

        for uniqueID in children("uniqueid", in: root) {
            guard let type = attribute("type", in: uniqueID)?.lowercased(),
                  let value = cleaned(uniqueID.text) else {
                continue
            }
            applyProviderID(type: type, value: value, tmdb: &tmdb, imdb: &imdb, tvdb: &tvdb)
        }

        if tmdb == nil,
           let value = childText("tmdbid", in: root) ?? childText("tmdb_id", in: root) {
            tmdb = Int(value)
        }
        if imdb == nil,
           let value = childText("imdbid", in: root) ?? childText("imdb_id", in: root) {
            imdb = normalizedIMDB(value)
        }
        if tvdb == nil,
           let value = childText("tvdbid", in: root) ?? childText("tvdb_id", in: root) {
            tvdb = Int(value)
        }

        return (tmdb, imdb, tvdb)
    }

    private func attribute(_ name: String, in node: XMLTreeNode) -> String? {
        node.attributes.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    private func applyProviderID(
        type: String,
        value: String,
        tmdb: inout Int?,
        imdb: inout String?,
        tvdb: inout Int?
    ) {
        switch type {
        case "tmdb":
            tmdb = tmdb ?? Int(value)
        case "imdb":
            imdb = imdb ?? normalizedIMDB(value)
        case "tvdb":
            tvdb = tvdb ?? Int(value)
        default:
            break
        }
    }

    private func normalizedIMDB(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("tt") {
            return lowered
        }
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) {
            return "tt" + trimmed
        }
        return nil
    }

    private func leadingInt(_ value: String) -> Int? {
        let digits = value.prefix { $0.isNumber }
        return Int(digits)
    }

    private func yearPrefix(_ value: String) -> Int? {
        let prefix = value.prefix(4)
        return Int(prefix)
    }

    // MARK: - Lenient fallback

    private struct LenientMatch {
        let value: String
        let range: Range<String.Index>
    }

    private func parseLeniently(_ data: Data) -> NFOMedia? {
        guard let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        let rootName = firstMatch(#"<\s*([A-Za-z][A-Za-z0-9_-]*)"#, in: raw)?.value
        guard let kind = kind(forRootName: rootName) else {
            return nil
        }

        let title = lenientText("title", in: raw) ?? ""
        let aired = lenientText("aired", in: raw) ?? lenientText("premiered", in: raw)
        var tmdb: Int?
        var imdb: String?
        var tvdb: Int?

        for match in allMatches(
            #"<uniqueid[^>]*type\s*=\s*["']([^"']+)["'][^>]*>(.*?)</uniqueid>"#,
            in: raw,
            groups: 2
        ) {
            applyProviderID(
                type: match[0].lowercased(),
                value: match[1],
                tmdb: &tmdb,
                imdb: &imdb,
                tvdb: &tvdb
            )
        }

        if tmdb == nil {
            tmdb = lenientText("tmdbid", in: raw).flatMap(Int.init)
        }
        if imdb == nil {
            imdb = lenientText("imdbid", in: raw).flatMap(normalizedIMDB)
        }
        if tvdb == nil {
            tvdb = lenientText("tvdbid", in: raw).flatMap(Int.init)
        }

        let genres = lenientTexts("genre", in: raw)
        let directors = lenientTexts("director", in: raw)

        guard !title.isEmpty
            || tmdb != nil
            || imdb != nil
            || tvdb != nil
            || !genres.isEmpty else {
            return nil
        }

        return NFOMedia(
            kind: kind,
            title: title,
            year: lenientText("year", in: raw).flatMap(Int.init)
                ?? aired.flatMap(yearPrefix),
            plot: lenientText("plot", in: raw) ?? lenientText("outline", in: raw),
            tagline: lenientText("tagline", in: raw),
            rating: lenientText("rating", in: raw).flatMap(Double.init),
            votes: lenientText("votes", in: raw).flatMap(leadingInt),
            runtimeMinutes: lenientText("runtime", in: raw).flatMap(leadingInt),
            mpaa: lenientText("mpaa", in: raw),
            genres: genres,
            directors: directors,
            tmdbID: tmdb,
            imdbID: imdb,
            tvdbID: tvdb,
            season: lenientText("season", in: raw).flatMap(Int.init),
            episode: lenientText("episode", in: raw).flatMap(Int.init),
            aired: aired
        )
    }

    private func lenientText(_ tag: String, in raw: String) -> String? {
        lenientTexts(tag, in: raw).first
    }

    private func lenientTexts(_ tag: String, in raw: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escaped)(?:\\s[^>]*)?>(.*?)(?:</\(escaped)>|$)"
        return allMatches(pattern, in: raw, groups: 1).compactMap { groups in
            guard let value = groups.first else {
                return nil
            }
            var cleanedValue = value.replacingOccurrences(
                of: #"(?s)<!\[CDATA\[(.*?)\]\]>"#,
                with: "$1",
                options: .regularExpression
            )
            cleanedValue = cleanedValue.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: .regularExpression
            )
            cleanedValue = decodeEntities(cleanedValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanedValue.isEmpty ? nil : cleanedValue
        }
    }

    private func decodeEntities(_ value: String) -> String {
        var decoded = value
        decoded = decoded.replacingOccurrences(of: "&lt;", with: "<")
        decoded = decoded.replacingOccurrences(of: "&gt;", with: ">")
        decoded = decoded.replacingOccurrences(of: "&quot;", with: "\"")
        decoded = decoded.replacingOccurrences(of: "&apos;", with: "'")
        decoded = decoded.replacingOccurrences(of: "&#39;", with: "'")
        decoded = decoded.replacingOccurrences(of: "&amp;", with: "&")
        return decoded
    }

    // MARK: - Regex helpers

    private func firstMatch(_ pattern: String, in text: String) -> LenientMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length)
              ),
              let fullRange = Range(match.range, in: text) else {
            return nil
        }
        if match.numberOfRanges > 1,
           let capturedRange = Range(match.range(at: 1), in: text) {
            return LenientMatch(value: String(text[capturedRange]), range: fullRange)
        }
        return LenientMatch(value: String(text[fullRange]), range: fullRange)
    }

    private func allMatches(
        _ pattern: String,
        in text: String,
        groups: Int
    ) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        ).compactMap { match in
            var values: [String] = []
            for group in 1...groups {
                guard match.range(at: group).location != NSNotFound,
                      let range = Range(match.range(at: group), in: text) else {
                    return nil
                }
                values.append(String(text[range]))
            }
            return values
        }
    }
}

// MARK: - XML tree

private final class XMLTreeNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLTreeNode] = []
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: XMLTreeNode?
    private var stack: [XMLTreeNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLTreeNode(name: elementName, attributes: attributeDict)
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
