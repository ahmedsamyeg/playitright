import Foundation
import Testing
@testable import MetadataKit

@Suite("FilenameParser Tests")
struct FilenameParserTests {
    private let parser = FilenameParser()

    private struct MovieCase: Sendable {
        let filename: String
        let title: String
        let year: Int
    }

    private struct EpisodeCase: Sendable {
        let filename: String
        let title: String
        let season: Int?
        let episodes: [Int]
        let resolution: String?
    }

    // MARK: - Movies

    @Test("Parses diverse movie release names")
    func parsesMovieReleases() {
        let cases: [MovieCase] = [
            MovieCase(filename: "Inception (2010) [2160p 4K HDR Atmos x265].mkv", title: "Inception", year: 2010),
            MovieCase(filename: "The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv", title: "The Matrix", year: 1999),
            MovieCase(filename: "Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-TERMiNAL.mkv", title: "Blade Runner 2049", year: 2017),
            MovieCase(filename: "2001.A.Space.Odyssey.1968.1080p.BluRay.x264-SPARKS.mkv", title: "2001 A Space Odyssey", year: 1968),
            MovieCase(filename: "1917.2019.2160p.WEB-DL.DDP5.1.Atmos.HEVC-CMRG.mkv", title: "1917", year: 2019),
            MovieCase(filename: "Parasite.2019.KOREAN.1080p.BluRay.x264.DTS-HD.MA.5.1-FGT.mkv", title: "Parasite", year: 2019),
            MovieCase(filename: "The.Grand.Budapest.Hotel.2014.1080p.BluRay.x264-AMIABLE.mkv", title: "The Grand Budapest Hotel", year: 2014),
            MovieCase(filename: "Spider-Man.Into.the.Spider-Verse.2018.2160p.WEB-DL.HDR10.DDP7.1.Atmos.HEVC-TEPES.mkv", title: "Spider-Man Into the Spider-Verse", year: 2018),
            MovieCase(filename: "Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.7.1.Atmos-FraMeSToR.mkv", title: "Dune Part Two", year: 2024),
            MovieCase(filename: "Oppenheimer (2023) 2160p 4K HDR10+ DTS-HD MA 5.1 x265.mkv", title: "Oppenheimer", year: 2023),
            MovieCase(filename: "The.Dark.Knight.2008.1080p.BluRay.DTS.x264-ESiR.mkv", title: "The Dark Knight", year: 2008),
            MovieCase(filename: "Amélie.2001.1080p.BluRay.x264-AMELIE.mkv", title: "Amélie", year: 2001),
            MovieCase(filename: "Spirited.Away.2001.2160p.UHD.BluRay.x265.10bit.HDR.DTS-HD.MA.5.1-SWTYBLZ.mkv", title: "Spirited Away", year: 2001),
            MovieCase(filename: "Everything.Everywhere.All.at.Once.2022.2160p.WEB-DL.DDP5.1.Atmos.HDR10.HEVC-CMRG.mkv", title: "Everything Everywhere All at Once", year: 2022),
            MovieCase(filename: "The.Lord.of.the.Rings.The.Fellowship.of.the.Ring.2001.Extended.Edition.1080p.BluRay.x264-ALLIANCE.mkv", title: "The Lord of the Rings The Fellowship of the Ring", year: 2001),
            MovieCase(filename: "Mad.Max.Fury.Road.2015.2160p.BluRay.x265.10bit.HDR.TrueHD.7.1.Atmos-BLOW.mkv", title: "Mad Max Fury Road", year: 2015),
            MovieCase(filename: "Whiplash (2014) [1080p] [BluRay] [x264] [DTS].mkv", title: "Whiplash", year: 2014),
            MovieCase(filename: "La.La.Land.2016.1080p.BluRay.x264.DTS-HD.MA.5.1-FGT.mkv", title: "La La Land", year: 2016),
            MovieCase(filename: "The.Shining.1980.2160p.UHD.BluRay.REMUX.HDR.HEVC.DTS-HD.MA.5.1-EPSiLON.mkv", title: "The Shining", year: 1980),
            MovieCase(filename: "Arrival.2016.1080p.BluRay.x264-SPARKS.mkv", title: "Arrival", year: 2016),
            MovieCase(filename: "Her.2013.1080p.BluRay.x264.YIFY.mkv", title: "Her", year: 2013),
            MovieCase(filename: "Alien.1979.Directors.Cut.1080p.BluRay.x264-GROUP.mkv", title: "Alien", year: 1979),
            MovieCase(filename: "The.Wolf.of.Wall.Street.2013.1080p.BluRay.x264-SPARKS.mkv", title: "The Wolf of Wall Street", year: 2013),
            MovieCase(filename: "Star.Wars.Episode.IV.A.New.Hope.1977.1080p.BluRay.x264-GROUP.mkv", title: "Star Wars Episode IV A New Hope", year: 1977),
            MovieCase(filename: "The.Godfather.Part.II.1974.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.7.1.Atmos-FraMeSToR.mkv", title: "The Godfather Part II", year: 1974),
            MovieCase(filename: "Se7en (1995) 1080p BluRay x264 DTS.mkv", title: "Se7en", year: 1995),
            MovieCase(filename: "12.Angry.Men.1957.1080p.BluRay.x264-GROUP.mkv", title: "12 Angry Men", year: 1957),
            MovieCase(filename: "Charlotte's.Web.2006.1080p.BluRay.x264-GROUP.mkv", title: "Charlotte's Web", year: 2006),
            MovieCase(filename: "Interstellar.2014.IMAX.2160p.UHD.BluRay.REMUX.HDR.HEVC.TrueHD.7.1.Atmos-GROUP.mkv", title: "Interstellar", year: 2014),
            MovieCase(filename: "Pulp.Fiction.1994.1080p.BluRay.x264-GROUP.mkv", title: "Pulp Fiction", year: 1994)
        ]

        for testCase in cases {
            let info = parser.parse(testCase.filename)
            #expect(info.kind == .movie, "\(testCase.filename)")
            #expect(info.title == testCase.title, "\(testCase.filename) → \(info.title)")
            #expect(info.year == testCase.year, "\(testCase.filename) → \(String(describing: info.year))")
        }
    }

    @Test("A filename without a year is still treated as a movie")
    func movieWithoutYear() {
        let info = parser.parse("The.Matrix.1080p.BluRay.x264-GROUP.mkv")

        #expect(info.kind == .movie)
        #expect(info.title == "The Matrix")
        #expect(info.year == nil)
        #expect(info.confidence < 0.9)
    }

    @Test("Parses paths as well as bare filenames")
    func parsesPath() {
        let info = parser.parse("/Volumes/Media/Movies/Inception (2010)/Inception.2010.2160p.mkv")

        #expect(info.kind == .movie)
        #expect(info.title == "Inception")
        #expect(info.year == 2010)
    }

    // MARK: - Episodes

    @Test("Parses diverse episode release names")
    func parsesEpisodeReleases() {
        let cases: [EpisodeCase] = [
            EpisodeCase(filename: "Breaking Bad S01E02-E03.mkv", title: "Breaking Bad", season: 1, episodes: [2, 3], resolution: nil),
            EpisodeCase(filename: "Show 1x02.mp4", title: "Show", season: 1, episodes: [2], resolution: nil),
            EpisodeCase(filename: "Anime - 12 [1080p].mkv", title: "Anime", season: nil, episodes: [12], resolution: "1080p"),
            EpisodeCase(filename: "The.Office.US.S02E12.1080p.WEB-DL.x264-GROUP.mkv", title: "The Office US", season: 2, episodes: [12], resolution: "1080p"),
            EpisodeCase(filename: "Game.of.Thrones.S08E06.2160p.WEB-DL.HDR.HEVC.DDP5.1.Atmos-GROUP.mkv", title: "Game of Thrones", season: 8, episodes: [6], resolution: "2160p"),
            EpisodeCase(filename: "Stranger.Things.S04E01E02.2160p.NF.WEB-DL.DDP5.1.Atmos.HDR.HEVC-NTb.mkv", title: "Stranger Things", season: 4, episodes: [1, 2], resolution: "2160p"),
            EpisodeCase(filename: "The.Mandalorian.S02E08.Chapter.16.1080p.DSNP.WEB-DL.x264-GROUP.mkv", title: "The Mandalorian", season: 2, episodes: [8], resolution: "1080p"),
            EpisodeCase(filename: "Friends.S05E14.The.One.Where.Everybody.Finds.Out.1080p.BluRay.x264-GROUP.mkv", title: "Friends", season: 5, episodes: [14], resolution: "1080p"),
            EpisodeCase(filename: "The.Sopranos.S01E01.720p.HDTV.x264-GROUP.mkv", title: "The Sopranos", season: 1, episodes: [1], resolution: "720p"),
            EpisodeCase(filename: "Doctor.Who.2005.S01E01.1080p.BluRay.x264-GROUP.mkv", title: "Doctor Who", season: 1, episodes: [1], resolution: "1080p"),
            EpisodeCase(filename: "Firefly.S01E01E02.1080p.BluRay.x264-GROUP.mkv", title: "Firefly", season: 1, episodes: [1, 2], resolution: "1080p"),
            EpisodeCase(filename: "Cowboy.Bebop.S01E05.1080p.BluRay.x265-GROUP.mkv", title: "Cowboy Bebop", season: 1, episodes: [5], resolution: "1080p"),
            EpisodeCase(filename: "Attack.on.Titan.S04E28.1080p.WEB.x264-GROUP.mkv", title: "Attack on Titan", season: 4, episodes: [28], resolution: "1080p"),
            EpisodeCase(filename: "Severance.S02E01.Hello.Ms.Cobel.2160p.ATVP.WEB-DL.DDP5.1.Atmos.HDR.HEVC-NTb.mkv", title: "Severance", season: 2, episodes: [1], resolution: "2160p"),
            EpisodeCase(filename: "The.Bear.S03E10.Forever.1080p.WEB-DL.x264-GROUP.mkv", title: "The Bear", season: 3, episodes: [10], resolution: "1080p"),
            EpisodeCase(filename: "Succession.S04E03.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb.mkv", title: "Succession", season: 4, episodes: [3], resolution: "1080p"),
            EpisodeCase(filename: "Ted.Lasso.S03E12.So.Long.Farewell.1080p.ATVP.WEB-DL.DDP5.1.Atmos.H.264-NTb.mkv", title: "Ted Lasso", season: 3, episodes: [12], resolution: "1080p"),
            EpisodeCase(filename: "Bluey.S03E49.1080p.WEB-DL.AAC2.0.H.264-GROUP.mkv", title: "Bluey", season: 3, episodes: [49], resolution: "1080p"),
            EpisodeCase(filename: "Planet.Earth.II.S01E06.2160p.UHD.BluRay.REMUX.HDR.HEVC.DTS-HD.MA.5.1-GROUP.mkv", title: "Planet Earth II", season: 1, episodes: [6], resolution: "2160p"),
            EpisodeCase(filename: "Chernobyl.S01E05.1080p.BluRay.x264-GROUP.mkv", title: "Chernobyl", season: 1, episodes: [5], resolution: "1080p"),
            EpisodeCase(filename: "Sherlock.S02E01.A.Scandal.in.Belgravia.1080p.BluRay.x264-GROUP.mkv", title: "Sherlock", season: 2, episodes: [1], resolution: "1080p"),
            EpisodeCase(filename: "The.Wire.S01E01.720p.HDTV.x264-GROUP.mkv", title: "The Wire", season: 1, episodes: [1], resolution: "720p"),
            EpisodeCase(filename: "Arcane.S01E09.2160p.NF.WEB-DL.DDP5.1.Atmos.HDR.HEVC-GROUP.mkv", title: "Arcane", season: 1, episodes: [9], resolution: "2160p"),
            EpisodeCase(filename: "One.Piece.S01E01.1080p.WEB-DL.AAC2.0.H.264-GROUP.mkv", title: "One Piece", season: 1, episodes: [1], resolution: "1080p"),
            EpisodeCase(filename: "Mr.Robot.S01E01.1080p.WEB-DL.x264-GROUP.mkv", title: "Mr Robot", season: 1, episodes: [1], resolution: "1080p"),
            EpisodeCase(filename: "Anime - 03v2 [720p].mkv", title: "Anime", season: nil, episodes: [3], resolution: "720p"),
            EpisodeCase(filename: "[Group] Show Name - 07 [1080p].mkv", title: "Show Name", season: nil, episodes: [7], resolution: "1080p"),
            EpisodeCase(filename: "Breaking.Bad.S01E01-03.1080p.BluRay.x264-GROUP.mkv", title: "Breaking Bad", season: 1, episodes: [1, 2, 3], resolution: "1080p"),
            EpisodeCase(filename: "The.Expanse.S02E05.1080p.WEB-DL.DD5.1.H.264-GROUP.mkv", title: "The Expanse", season: 2, episodes: [5], resolution: "1080p"),
            EpisodeCase(filename: "Better.Call.Saul.S06E13.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb.mkv", title: "Better Call Saul", season: 6, episodes: [13], resolution: "1080p")
        ]

        for testCase in cases {
            let info = parser.parse(testCase.filename)
            #expect(info.kind == .episode, "\(testCase.filename)")
            #expect(info.title == testCase.title, "\(testCase.filename) → \(info.title)")
            #expect(info.season == testCase.season, "\(testCase.filename) → \(String(describing: info.season))")
            #expect(info.episodes == testCase.episodes, "\(testCase.filename) → \(info.episodes)")
            #expect(info.resolution == testCase.resolution, "\(testCase.filename) → \(String(describing: info.resolution))")
        }
    }

    @Test("Expands multi-episode ranges")
    func multiEpisodeRanges() {
        let hyphen = parser.parse("Show.S01E01-E04.1080p.mkv")
        #expect(hyphen.isMultiEpisode)
        #expect(hyphen.episodes == [1, 2, 3, 4])
        #expect(hyphen.episodeStart == 1)
        #expect(hyphen.episodeEnd == 4)

        let compact = parser.parse("Show.S01E01E02.mkv")
        #expect(compact.episodes == [1, 2])

        let dashShort = parser.parse("Show.S01E01-03.mkv")
        #expect(dashShort.episodes == [1, 2, 3])

        let cross = parser.parse("Show 1x02x04.mkv")
        #expect(cross.episodes == [2, 4])
    }

    @Test("Episode keyword and absolute numbering are recognised")
    func keywordAndAbsoluteNumbering() {
        let keyword = parser.parse("Some Show Episode 12 1080p.mkv")
        #expect(keyword.kind == .episode)
        #expect(keyword.title == "Some Show")
        #expect(keyword.episodes == [12])

        let absolute = parser.parse("Some Anime - 24v2 [1080p].mkv")
        #expect(absolute.kind == .episode)
        #expect(absolute.episodes == [24])
        #expect(absolute.needsReview)
    }

    // MARK: - Technical attributes

    @Test("Extracts resolution, codecs, HDR, and release groups")
    func extractsTechnicalAttributes() {
        let inception = parser.parse("Inception (2010) [2160p 4K HDR Atmos x265].mkv")
        #expect(inception.resolution == "2160p")
        #expect(inception.videoCodec == "hevc")
        #expect(inception.audioCodec == "atmos")
        #expect(inception.hdrFormats.contains("hdr10"))
        #expect(inception.releaseGroup == nil)

        let matrix = parser.parse("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv")
        #expect(matrix.resolution == "1080p")
        #expect(matrix.videoCodec == "h264")
        #expect(matrix.releaseGroup == "GROUP")

        let dune = parser.parse("Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.7.1.Atmos-FraMeSToR.mkv")
        #expect(dune.hdrFormats.contains("dolby-vision"))
        #expect(dune.hdrFormats.contains("hdr10"))
        #expect(dune.audioCodec == "truehd")
        #expect(dune.releaseGroup == "FraMeSToR")

        let oppenheimer = parser.parse("Oppenheimer (2023) 2160p 4K HDR10+ DTS-HD MA 5.1 x265.mkv")
        #expect(oppenheimer.hdrFormats == ["hdr10+"])
        #expect(oppenheimer.audioCodec == "dts-hd-ma")

        let succession = parser.parse("Succession.S04E03.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb.mkv")
        #expect(succession.videoCodec == "h264")
        #expect(succession.audioCodec == "eac3")
        #expect(succession.releaseGroup == "NTb")

        let bluey = parser.parse("Bluey.S03E49.1080p.WEB-DL.AAC2.0.H.264-GROUP.mkv")
        #expect(bluey.audioCodec == "aac")
        #expect(bluey.videoCodec == "h264")
    }

    @Test("Extracts edition labels")
    func extractsEditions() {
        let alien = parser.parse("Alien.1979.Directors.Cut.1080p.BluRay.x264-GROUP.mkv")
        #expect(alien.edition == "Director's Cut")

        let fellowship = parser.parse("The.Lord.of.the.Rings.The.Fellowship.of.the.Ring.2001.Extended.Edition.1080p.BluRay.x264-ALLIANCE.mkv")
        #expect(fellowship.edition == "Extended Edition")

        let interstellar = parser.parse("Interstellar.2014.IMAX.2160p.UHD.BluRay.REMUX.HDR.HEVC.TrueHD.7.1.Atmos-GROUP.mkv")
        #expect(interstellar.edition == "IMAX")
    }

    // MARK: - Confidence

    @Test("Confidence reflects how unambiguous the filename is")
    func confidenceScores() {
        let cleanMovie = parser.parse("Inception.2010.1080p.BluRay.x264-GROUP.mkv")
        #expect(cleanMovie.confidence >= 0.9)
        #expect(!cleanMovie.needsReview)

        let cleanEpisode = parser.parse("Breaking.Bad.S01E02.1080p.mkv")
        #expect(cleanEpisode.confidence >= 0.9)
        #expect(!cleanEpisode.needsReview)

        let crossSeason = parser.parse("Show 1x02.mkv")
        #expect(crossSeason.confidence >= 0.85)

        let animeAbsolute = parser.parse("Anime - 12 [1080p].mkv")
        #expect(animeAbsolute.confidence < 0.75)
        #expect(animeAbsolute.needsReview)

        let noYear = parser.parse("Some.Movie.1080p.BluRay.x264-GROUP.mkv")
        #expect(noYear.confidence < 0.9)
        #expect(noYear.confidence >= 0.7)

        let junk = parser.parse("1080p.mkv")
        #expect(junk.title.isEmpty)
        #expect(junk.confidence < 0.5)
        #expect(junk.needsReview)
    }

    @Test("Ambiguous episode titles keep a usable title")
    func ambiguousEpisodeTitle() {
        let info = parser.parse("Show Name - 99 [720p].mkv")

        #expect(info.kind == .episode)
        #expect(info.title == "Show Name")
        #expect(info.episodes == [99])
    }

    @Test("Parsed info round-trips through Codable")
    func codableRoundTrip() throws {
        let info = parser.parse("Inception (2010) [2160p HDR Atmos x265].mkv")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ParsedMediaInfo.self, from: data)

        #expect(decoded == info)
    }
}
