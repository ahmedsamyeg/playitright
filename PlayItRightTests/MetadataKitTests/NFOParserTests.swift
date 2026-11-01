import Foundation
import Testing
@testable import MetadataKit

@Suite("NFOParser Tests")
struct NFOParserTests {
    private let parser = NFOParser()

    private let movieXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <movie>
      <title>Inception</title>
      <originaltitle>Inception</originaltitle>
      <sorttitle>Inception</sorttitle>
      <year>2010</year>
      <plot><![CDATA[A thief who steals corporate secrets through dream-sharing.]]></plot>
      <tagline>Your mind is the scene of the crime.</tagline>
      <runtime>148 min</runtime>
      <mpaa>PG-13</mpaa>
      <rating>8.8</rating>
      <votes>2400000</votes>
      <uniqueid type="tmdb" default="true">27205</uniqueid>
      <uniqueid type="imdb">tt1375666</uniqueid>
      <uniqueid type="tvdb">12345</uniqueid>
      <genre>Action</genre>
      <genre>Science Fiction</genre>
      <director>Christopher Nolan</director>
      <actor>
        <name>Leonardo DiCaprio</name>
        <role>Cobb</role>
        <order>0</order>
        <thumb>https://image.example/leo.jpg</thumb>
      </actor>
      <actor>
        <name>Joseph Gordon-Levitt</name>
        <role>Arthur</role>
        <order>1</order>
      </actor>
    </movie>
    """

    // MARK: - Movies

    @Test("Parses a movie NFO with TMDB, IMDB, and TVDB ids")
    func parsesMovieNFO() {
        let media = parser.parse(xml: movieXML)

        #expect(media != nil)
        #expect(media?.kind == .movie)
        #expect(media?.title == "Inception")
        #expect(media?.originalTitle == "Inception")
        #expect(media?.sortTitle == "Inception")
        #expect(media?.year == 2010)
        #expect(media?.plot == "A thief who steals corporate secrets through dream-sharing.")
        #expect(media?.tagline == "Your mind is the scene of the crime.")
        #expect(media?.runtimeMinutes == 148)
        #expect(media?.mpaa == "PG-13")
        #expect(media?.rating == 8.8)
        #expect(media?.votes == 2_400_000)
        #expect(media?.tmdbID == 27205)
        #expect(media?.imdbID == "tt1375666")
        #expect(media?.tvdbID == 12345)
        #expect(media?.genres == ["Action", "Science Fiction"])
        #expect(media?.directors == ["Christopher Nolan"])
        #expect(media?.cast.map(\.name) == ["Leonardo DiCaprio", "Joseph Gordon-Levitt"])
        #expect(media?.cast.first?.role == "Cobb")
        #expect(media?.cast.first?.order == 0)
        #expect(media?.cast.first?.imageURL == "https://image.example/leo.jpg")
        #expect(media?.season == nil)
        #expect(media?.episode == nil)
    }

    @Test("Supports Emby-style legacy provider id elements")
    func parsesLegacyProviderIDs() {
        let xml = """
        <movie>
          <title>The Matrix</title>
          <year>1999</year>
          <tmdbid>603</tmdbid>
          <imdbid>0133093</imdbid>
          <tvdbid>169</tvdbid>
        </movie>
        """

        let media = parser.parse(xml: xml)

        #expect(media?.title == "The Matrix")
        #expect(media?.year == 1999)
        #expect(media?.tmdbID == 603)
        #expect(media?.imdbID == "tt0133093")
        #expect(media?.tvdbID == 169)
    }

    @Test("Reads nested Kodi ratings blocks")
    func parsesNestedRatings() {
        let xml = """
        <movie>
          <title>Arrival</title>
          <year>2016</year>
          <ratings>
            <rating name="tmdb" max="10">
              <value>7.6</value>
              <votes>123456</votes>
            </rating>
          </ratings>
        </movie>
        """

        let media = parser.parse(xml: xml)

        #expect(media?.rating == 7.6)
        #expect(media?.votes == 123_456)
    }

    // MARK: - TV

    @Test("Parses a TV show NFO")
    func parsesTVShowNFO() {
        let xml = """
        <tvshow>
          <title>Breaking Bad</title>
          <originaltitle>Breaking Bad</originaltitle>
          <year>2008</year>
          <plot>A chemistry teacher turns to manufacturing.</plot>
          <uniqueid type="tmdb">1396</uniqueid>
          <uniqueid type="tvdb">81189</uniqueid>
          <uniqueid type="imdb">tt0903747</uniqueid>
          <genre>Drama</genre>
          <genre>Crime</genre>
          <director>Vince Gilligan</director>
          <actor>
            <name>Bryan Cranston</name>
            <role>Walter White</role>
            <order>0</order>
          </actor>
        </tvshow>
        """

        let media = parser.parse(xml: xml)

        #expect(media?.kind == .tvShow)
        #expect(media?.title == "Breaking Bad")
        #expect(media?.year == 2008)
        #expect(media?.plot == "A chemistry teacher turns to manufacturing.")
        #expect(media?.tmdbID == 1396)
        #expect(media?.tvdbID == 81189)
        #expect(media?.imdbID == "tt0903747")
        #expect(media?.genres == ["Drama", "Crime"])
        #expect(media?.cast.map(\.name) == ["Bryan Cranston"])
    }

    @Test("Parses an episode NFO with season and episode numbers")
    func parsesEpisodeNFO() {
        let xml = """
        <episodedetails>
          <title>Pilot</title>
          <season>1</season>
          <episode>1</episode>
          <plot>Walter White begins his descent.</plot>
          <rating>8.2</rating>
          <votes>5000</votes>
          <uniqueid type="tmdb">62085</uniqueid>
          <uniqueid type="imdb">tt0959621</uniqueid>
          <director>Vince Gilligan</director>
          <aired>2008-01-20</aired>
        </episodedetails>
        """

        let media = parser.parse(xml: xml)

        #expect(media?.kind == .episode)
        #expect(media?.title == "Pilot")
        #expect(media?.season == 1)
        #expect(media?.episode == 1)
        #expect(media?.year == 2008)
        #expect(media?.aired == "2008-01-20")
        #expect(media?.plot == "Walter White begins his descent.")
        #expect(media?.rating == 8.2)
        #expect(media?.tmdbID == 62085)
        #expect(media?.imdbID == "tt0959621")
        #expect(media?.directors == ["Vince Gilligan"])
    }

    @Test("Parses absolute episode numbers")
    func parsesAbsoluteEpisode() {
        let xml = """
        <episodedetails>
          <title>Episode 42</title>
          <season>3</season>
          <episode>6</episode>
          <absoluteepisode>42</absoluteepisode>
        </episodedetails>
        """

        let media = parser.parse(xml: xml)

        #expect(media?.season == 3)
        #expect(media?.episode == 6)
        #expect(media?.absoluteEpisode == 42)
    }

    // MARK: - Malformed input

    @Test("Malformed XML recovers readable fields without throwing")
    func malformedXMLRecovers() {
        let xml = """
        <movie>
          <title>Tom & Jerry</title>
          <year>2021</year>
          <plot>Cat & mouse.</plot>
          <uniqueid type="tmdb">123</uniqueid>
        </movie>
        """

        let media = parser.parse(xml: xml)

        #expect(media != nil)
        #expect(media?.kind == .movie)
        #expect(media?.title == "Tom & Jerry")
        #expect(media?.year == 2021)
        #expect(media?.plot == "Cat & mouse.")
        #expect(media?.tmdbID == 123)
    }

    @Test("Truncated XML keeps the fields it can read")
    func truncatedXMLRecovers() {
        let media = parser.parse(xml: "<movie><title>Broken</title><year>1999")

        #expect(media?.kind == .movie)
        #expect(media?.title == "Broken")
        #expect(media?.year == 1999)
    }

    @Test("Completely invalid input returns nil")
    func invalidInputReturnsNil() {
        #expect(parser.parse(Data()) == nil)
        #expect(parser.parse(xml: "not xml at all") == nil)
        #expect(parser.parse(xml: "") == nil)
    }

    // MARK: - Sidecar text

    @Test("Parses sidecar text files")
    func parsesSidecarText() {
        let sidecar = parser.parse(text: "Inception (2010)\n")
        #expect(sidecar?.kind == .movie)
        #expect(sidecar?.title == "Inception")
        #expect(sidecar?.year == 2010)

        let prefixed = parser.parse(text: "Title: The Matrix 1999\n")
        #expect(prefixed?.title == "The Matrix")
        #expect(prefixed?.year == 1999)

        let bare = parser.parse(text: "Blade Runner\n")
        #expect(bare?.title == "Blade Runner")
        #expect(bare?.year == nil)

        #expect(parser.parse(text: "2010\n") == nil)
        #expect(parser.parse(text: "   \n\n") == nil)
    }

    // MARK: - File loading

    @Test("Loads .nfo and .txt sidecar files from disk")
    func loadsFilesFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NFOParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let nfoURL = directory.appendingPathComponent("Inception.nfo")
        try movieXML.write(to: nfoURL, atomically: true, encoding: .utf8)

        let sidecarURL = directory.appendingPathComponent("The Matrix 1999.txt")
        try "The Matrix (1999)".write(to: sidecarURL, atomically: true, encoding: .utf8)

        let fromNFO = parser.parse(contentsOf: nfoURL)
        #expect(fromNFO?.title == "Inception")
        #expect(fromNFO?.tmdbID == 27205)

        let fromSidecar = parser.parse(contentsOf: sidecarURL)
        #expect(fromSidecar?.title == "The Matrix")
        #expect(fromSidecar?.year == 1999)

        let missing = directory.appendingPathComponent("missing.nfo")
        #expect(parser.parse(contentsOf: missing) == nil)
    }

    // MARK: - Priority merge

    @Test("Local NFO fields override remote metadata")
    func localNFOOverridesRemote() {
        let remote = NFOMedia(
            kind: .movie,
            title: "Inception (remote)",
            year: 2010,
            plot: "Remote plot",
            rating: 8.0,
            genres: ["Action", "Thriller"],
            directors: ["Remote Director"],
            cast: [NFOCastMember(name: "Remote Actor")],
            tmdbID: 27205
        )
        let local = NFOMedia(
            kind: .movie,
            title: "Inception",
            year: 2010,
            rating: 9.0,
            imdbID: "tt1375666"
        )

        let merged = local.overriding(remote)

        #expect(merged.title == "Inception")
        #expect(merged.plot == "Remote plot")
        #expect(merged.rating == 9.0)
        #expect(merged.genres == ["Action", "Thriller"])
        #expect(merged.directors == ["Remote Director"])
        #expect(merged.cast.first?.name == "Remote Actor")
        #expect(merged.tmdbID == 27205)
        #expect(merged.imdbID == "tt1375666")
        #expect(merged.year == 2010)
    }

    @Test("A sparse local NFO does not erase remote text")
    func sparseLocalNFOFallsThrough() {
        let remote = NFOMedia(
            kind: .tvShow,
            title: "Breaking Bad",
            plot: "Remote plot",
            genres: ["Drama"],
            tmdbID: 1396
        )
        let local = NFOMedia(kind: .tvShow, title: "")

        let merged = local.overriding(remote)

        #expect(merged.kind == .tvShow)
        #expect(merged.title == "Breaking Bad")
        #expect(merged.plot == "Remote plot")
        #expect(merged.genres == ["Drama"])
        #expect(merged.tmdbID == 1396)
    }

    @Test("NFOMedia round-trips through Codable")
    func codableRoundTrip() throws {
        let media = parser.parse(xml: movieXML)
        let data = try JSONEncoder().encode(media)
        let decoded = try JSONDecoder().decode(NFOMedia.self, from: data)

        #expect(decoded == media)
    }
}
