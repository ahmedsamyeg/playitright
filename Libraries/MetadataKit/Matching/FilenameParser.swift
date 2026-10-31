import Foundation

/// Parses release filenames into provider-searchable metadata (MD-1).
///
/// The parser is intentionally tolerant: it never throws, always returns a
/// best-effort result, and reports a confidence score so callers can route
/// ambiguous names to the "Fix matching" flow (MD-2).
public struct FilenameParser: Sendable {
    public init() {}

    /// Parses a filename or path.
    public func parse(_ filename: String) -> ParsedMediaInfo {
        let base = Self.baseName(filename)
        var working = Self.normalize(base)

        let releaseGroup = Self.extractReleaseGroup(from: &working)
        let episode = Self.detectEpisode(in: working)
        let yearMatch = episode == nil ? Self.detectYear(in: working) : nil

        let titleEnd: String.Index
        if let episode {
            titleEnd = episode.range.lowerBound
        } else if let yearMatch {
            titleEnd = yearMatch.range.lowerBound
        } else {
            titleEnd = working.endIndex
        }

        let attributes = Self.extractAttributes(from: working)
        var title = Self.cleanTitle(String(working[..<titleEnd]))

        if episode != nil {
            title = Self.stripTrailingYear(from: title)
        }

        let kind: MediaKind = episode == nil ? .movie : .episode
        let confidence: Double
        switch kind {
        case .movie:
            if !title.isEmpty && yearMatch != nil {
                confidence = 0.9
            } else if !title.isEmpty {
                confidence = 0.7
            } else {
                confidence = 0.2
            }
        case .episode:
            switch episode?.style {
            case .seasonEpisode:
                confidence = title.isEmpty ? 0.4 : 0.95
            case .crossSeason:
                confidence = title.isEmpty ? 0.4 : 0.9
            case .keyword:
                confidence = title.isEmpty ? 0.4 : 0.85
            case .animeAbsolute:
                confidence = title.isEmpty ? 0.3 : 0.65
            case .none:
                confidence = 0.3
            }
        }

        return ParsedMediaInfo(
            kind: kind,
            title: title,
            year: yearMatch?.year,
            season: episode?.season,
            episodes: episode?.episodes ?? [],
            edition: attributes.edition,
            resolution: attributes.resolution,
            videoCodec: attributes.videoCodec,
            audioCodec: attributes.audioCodec,
            hdrFormats: attributes.hdrFormats,
            releaseGroup: releaseGroup,
            confidence: confidence,
            sourceFilename: filename
        )
    }

    // MARK: - Filename normalization

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "mts", "webm",
        "wmv", "mpg", "mpeg", "iso", "flv", "ogv", "vob", "divx"
    ]

    private static func baseName(_ filename: String) -> String {
        let lastComponent = (filename as NSString).lastPathComponent
        guard let dot = lastComponent.lastIndex(of: ".") else {
            return lastComponent
        }
        let ext = lastComponent[lastComponent.index(after: dot)...].lowercased()
        return videoExtensions.contains(ext)
            ? String(lastComponent[..<dot])
            : lastComponent
    }

    private static func normalize(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: "_", with: " ")
        value = value.replacingOccurrences(of: ".", with: " ")
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Release groups

    private static func extractReleaseGroup(from working: inout String) -> String? {
        // Leading `[Group] Title...`
        if let match = firstMatch(#"^\s*\[([^\]]{1,40})\]\s+"#, in: working),
           !isTechnicalGroup(match.value) {
            working.removeSubrange(match.range)
            working = normalize(working)
            return match.value.trimmingCharacters(in: .whitespaces)
        }

        // Trailing `[GROUP]` (but not `[1080p]` or `[x264]`).
        if let match = firstMatch(#"\s*\[([A-Za-z][A-Za-z0-9._ -]{0,39})\]\s*$"#, in: working),
           !isTechnicalGroup(match.value) {
            working.removeSubrange(match.range)
            working = normalize(working)
            return match.value.trimmingCharacters(in: .whitespaces)
        }

        // Trailing `-GROUP`, only when the preceding tokens look like a release.
        if let match = firstMatch(#"-([A-Za-z][A-Za-z0-9._-]{1,24})$"#, in: working) {
            let prefix = String(working[..<match.range.lowerBound])
            if isTechnicalContext(prefix) {
                working.removeSubrange(match.range)
                working = normalize(working)
                return match.value
            }
        }

        return nil
    }

    private static func isTechnicalGroup(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let markers = [
            "2160p", "1080p", "720p", "480p", "4k", "uhd", "8k", "hdr",
            "bluray", "blu-ray", "web", "x264", "x265", "h264", "h265",
            "hevc", "avc", "av1", "dts", "aac", "ac3", "eac3", "ddp", "atmos"
        ]
        return markers.contains { lowered.contains($0) }
    }

    private static func isTechnicalContext(_ text: String) -> Bool {
        isTechnicalGroup(text)
    }

    // MARK: - Episode detection

    private enum EpisodeStyle {
        case seasonEpisode
        case crossSeason
        case keyword
        case animeAbsolute
    }

    private struct EpisodeDetection {
        let season: Int?
        let episodes: [Int]
        let range: Range<String.Index>
        let style: EpisodeStyle
    }

    private static func detectEpisode(in text: String) -> EpisodeDetection? {
        // S01E02, S01E02-E03, S01E02E03, S01E02-03
        let seasonPattern = #"(?i)(?:^|[\s._\[\(\{])s(\d{1,2})[\s._-]*e(\d{1,4})((?:[\s._-]*(?:-[\s._-]*e?|e)[\s._-]*\d{1,4})*)"#
        if let match = fullMatch(seasonPattern, in: text, captureGroups: 3) {
            let season = Int(match.values[0]) ?? 1
            let start = Int(match.values[1]) ?? 1
            let episodes = parseEpisodeContinuation(match.values[2], start: start)
            return EpisodeDetection(
                season: season,
                episodes: episodes,
                range: match.range,
                style: .seasonEpisode
            )
        }

        // 1x02, 1x02x03
        let crossPattern = #"(?i)(?:^|[\s._\[\(\{])(\d{1,2})x(\d{1,4})((?:[\s._-]*x[\s._-]*\d{1,4})*)"#
        if let match = fullMatch(crossPattern, in: text, captureGroups: 3) {
            let season = Int(match.values[0]) ?? 1
            let start = Int(match.values[1]) ?? 1
            let episodes = parseEpisodeContinuation(match.values[2], start: start)
            return EpisodeDetection(
                season: season,
                episodes: episodes,
                range: match.range,
                style: .crossSeason
            )
        }

        // Episode 12 / Ep 12
        let keywordPattern = #"(?i)(?:^|[\s._\[\(\{])(?:episode|ep)[\s._-]*(\d{1,4})(?!\d)"#
        if let match = fullMatch(keywordPattern, in: text, captureGroups: 1) {
            let number = Int(match.values[0]) ?? 1
            return EpisodeDetection(
                season: nil,
                episodes: [number],
                range: match.range,
                style: .keyword
            )
        }

        // Anime absolute numbering: `Anime - 12 [1080p]`.
        let animePattern = #"(?:^|[\s._])-[\s._]+(\d{1,4})(?:v\d+)?(?=$|[\s._\[\]\(\)-])"#
        if let match = fullMatch(animePattern, in: text, captureGroups: 1) {
            let number = Int(match.values[0]) ?? 1
            return EpisodeDetection(
                season: nil,
                episodes: [number],
                range: match.range,
                style: .animeAbsolute
            )
        }

        return nil
    }

    private static func parseEpisodeContinuation(_ continuation: String, start: Int) -> [Int] {
        guard !continuation.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"(?i)([\s._]*)(-\s*e?|e|x)?[\s._-]*(\d{1,4})"#
              ) else {
            return [start]
        }

        let ns = continuation as NSString
        let matches = regex.matches(
            in: continuation,
            range: NSRange(location: 0, length: ns.length)
        )

        var numbers = [start]
        var hasRange = false

        for match in matches {
            if match.range(at: 2).location != NSNotFound,
               let separator = Range(match.range(at: 2), in: continuation) {
                if continuation[separator].hasPrefix("-") {
                    hasRange = true
                }
            }
            if let range = Range(match.range(at: 3), in: continuation),
               let number = Int(continuation[range]),
               !numbers.contains(number) {
                numbers.append(number)
            }
        }

        if hasRange, let maximum = numbers.max(), maximum > start,
           maximum - start <= 100 {
            return Array(start...maximum)
        }
        return numbers
    }

    // MARK: - Year detection

    private struct YearMatch {
        let year: Int
        let range: Range<String.Index>
    }

    private static func detectYear(in text: String) -> YearMatch? {
        if let match = fullMatch(#"[\(\[]\s*((?:19|20)\d{2})\s*[\)\]]"#, in: text, captureGroups: 1),
           let year = Int(match.values[0]) {
            return YearMatch(year: year, range: match.range)
        }

        let regex = #"(?<![\d])((?:19|20)\d{2})(?![\d])"#
        guard let expression = try? NSRegularExpression(pattern: regex) else {
            return nil
        }

        let ns = text as NSString
        let matches = expression.matches(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        )

        let currentYear = Calendar(identifier: .gregorian)
            .component(.year, from: Date())

        var candidates: [YearMatch] = []
        for match in matches {
            guard let yearRange = Range(match.range(at: 1), in: text),
                  let year = Int(text[yearRange]),
                  year <= currentYear + 1 else {
                continue
            }
            let prefix = text[..<yearRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A leading year is usually part of the title (`1917`, `2001`).
            if prefix.isEmpty {
                continue
            }
            candidates.append(YearMatch(year: year, range: yearRange))
        }

        // Prefer the last plausible year; release tags follow the title.
        return candidates.last
    }

    private static func stripTrailingYear(from title: String) -> String {
        guard let match = firstMatch(#"\s+((?:19|20)\d{2})$"#, in: title) else {
            return title
        }
        let currentYear = Calendar(identifier: .gregorian)
            .component(.year, from: Date())
        guard let year = Int(match.value), year <= currentYear + 1 else {
            return title
        }
        var trimmed = title
        trimmed.removeSubrange(match.range)
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Technical attributes

    private struct TechnicalAttributes {
        var resolution: String?
        var videoCodec: String?
        var audioCodec: String?
        var hdrFormats: [String] = []
        var edition: String?
    }

    private static let resolutionPattern =
        #"(?i)(?<![a-z0-9])(4320p|2160p|1440p|1080p|1080i|720p|576p|480p|8k|4k|uhd)(?![a-z0-9])"#

    private static let videoCodecPattern =
        #"(?i)(?<![a-z0-9])(x265|h[\s.-]?265|hevc|x264|h[\s.-]?264|avc|av1|vp9|mpeg[\s.-]?2|vc[\s.-]?1|xvid|divx|prores)(?![a-z0-9])"#

    private static let audioCodecPattern =
        #"(?i)(?<![a-z0-9])(atmos|truehd|dts[\s.-]?hd[\s.-]?ma|dts[\s.-]?hd|dts|e-?ac-?3|ddp(?:\d(?:[\s.]\d)?)?|dd\+|ac-?3|aac(?:\d(?:[\s.]\d)?)?|flac|opus|mp3)(?![a-z0-9])"#

    private static let hdrPattern =
        #"(?i)(?<![a-z0-9])(hdr10\+|hdr10|hdr|hlg|dolby[\s.-]?vision|dovi|dv)(?![a-z0-9])"#

    private static let editionPattern =
        #"(?i)(?<![a-z0-9])(director'?s[\s.-]?cut|extended(?:[\s.-]?(?:edition|cut))?|unrated|remastered|imax|theatrical(?:[\s.-]?cut)?|special[\s.-]?edition|final[\s.-]?cut)(?![a-z0-9])"#

    private static let releaseJunkPattern =
        #"(?i)(?<![a-z0-9])(blu-?ray|bdrip|brrip|web-?dl|webrip|hdtv|dvdrip|remux|hdrip|ppv|amzn|dsnp|atvp|hmax|itunes)(?![a-z0-9])"#

    private static let miscJunkPattern =
        #"(?i)(?<![a-z0-9])(?:10|8)[\s.-]?bit(?![a-z0-9])|\b\d{2,3}fps\b|\b(?:proper|repack|rerip|internal)\b"#

    private static func extractAttributes(from text: String) -> TechnicalAttributes {
        var attributes = TechnicalAttributes()

        if let value = firstMatch(resolutionPattern, in: text)?.value {
            attributes.resolution = canonicalResolution(value)
        }
        if let value = firstMatch(videoCodecPattern, in: text)?.value {
            attributes.videoCodec = canonicalVideoCodec(value)
        }
        if let value = firstMatch(audioCodecPattern, in: text)?.value {
            attributes.audioCodec = canonicalAudioCodec(value)
        }
        if let value = firstMatch(editionPattern, in: text)?.value {
            attributes.edition = canonicalEdition(value)
        }

        for match in allMatches(hdrPattern, in: text) {
            let canonical = canonicalHDR(match)
            if !attributes.hdrFormats.contains(canonical) {
                attributes.hdrFormats.append(canonical)
            }
        }

        return attributes
    }

    private static func canonicalResolution(_ value: String) -> String {
        switch value.lowercased() {
        case "4k", "uhd", "2160p": return "2160p"
        case "8k", "4320p": return "4320p"
        default: return value.lowercased()
        }
    }

    private static func canonicalVideoCodec(_ value: String) -> String {
        let compact = value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch compact {
        case "x265", "h265", "hevc": return "hevc"
        case "x264", "h264", "avc": return "h264"
        case "av1": return "av1"
        case "vp9": return "vp9"
        case "mpeg2": return "mpeg2"
        case "vc1": return "vc1"
        case "xvid": return "xvid"
        case "divx": return "divx"
        case "prores": return "prores"
        default: return compact
        }
    }

    private static func canonicalAudioCodec(_ value: String) -> String {
        let compact = value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch compact {
        case "atmos": return "atmos"
        case "truehd": return "truehd"
        case "dtshdma": return "dts-hd-ma"
        case "dtshd": return "dts-hd"
        case "dts": return "dts"
        case "eac3": return "eac3"
        case "ac3": return "ac3"
        case "aac": return "aac"
        case "flac": return "flac"
        case "opus": return "opus"
        case "mp3": return "mp3"
        default:
            if compact.hasPrefix("ddp") || compact.hasPrefix("dd+") {
                return "eac3"
            }
            if compact.hasPrefix("aac") {
                return "aac"
            }
            return compact
        }
    }

    private static func canonicalHDR(_ value: String) -> String {
        let compact = value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch compact {
        case "hdr10+": return "hdr10+"
        case "hdr10", "hdr": return "hdr10"
        case "hlg": return "hlg"
        case "dolbyvision", "dovi", "dv": return "dolby-vision"
        default: return compact
        }
    }

    private static func canonicalEdition(_ value: String) -> String {
        let compact = value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "'", with: "")
        switch compact {
        case "directorscut": return "Director's Cut"
        case "extendededition": return "Extended Edition"
        case "extendedcut": return "Extended Cut"
        case "extended": return "Extended"
        case "unrated": return "Unrated"
        case "remastered": return "Remastered"
        case "imax": return "IMAX"
        case "theatricalcut": return "Theatrical Cut"
        case "theatrical": return "Theatrical"
        case "specialedition": return "Special Edition"
        case "finalcut": return "Final Cut"
        default: return value
        }
    }

    // MARK: - Title cleanup

    private static func cleanTitle(_ raw: String) -> String {
        var title = raw

        for pattern in [
            resolutionPattern,
            videoCodecPattern,
            audioCodecPattern,
            hdrPattern,
            editionPattern,
            releaseJunkPattern,
            miscJunkPattern
        ] {
            title = removeAllMatches(pattern, from: title)
        }

        // Brackets whose technical contents have just been removed.
        title = title.replacingOccurrences(
            of: #"[\[\(\{]\s*[\]\)\}]"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(
            in: CharacterSet(charactersIn: " -–—_.:,;[](){}")
        )
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Regex helpers

    private struct Match {
        let value: String
        let range: Range<String.Index>
    }

    private struct MultiMatch {
        let values: [String]
        let range: Range<String.Index>
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        ), let fullRange = Range(match.range, in: text) else {
            return nil
        }
        if match.numberOfRanges > 1,
           let capturedRange = Range(match.range(at: 1), in: text) {
            return Match(value: String(text[capturedRange]), range: fullRange)
        }
        return Match(value: String(text[fullRange]), range: fullRange)
    }

    private static func fullMatch(
        _ pattern: String,
        in text: String,
        captureGroups: Int
    ) -> MultiMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length)
              ),
              let fullRange = Range(match.range, in: text) else {
            return nil
        }

        var values: [String] = []
        for group in 1...captureGroups {
            if match.range(at: group).location != NSNotFound,
               let range = Range(match.range(at: group), in: text) {
                values.append(String(text[range]))
            } else {
                values.append("")
            }
        }
        return MultiMatch(values: values, range: fullRange)
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let ns = text as NSString
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        ).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private static func removeAllMatches(_ pattern: String, from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let nsText = text as NSString
        let mutable = NSMutableString(string: text)
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "")
        }
        return mutable as String
    }
}
