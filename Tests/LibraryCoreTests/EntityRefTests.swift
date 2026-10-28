import Testing
@testable import LibraryCore

@Suite("EntityRef Tests")
struct EntityRefTests {
    @Test("Movie reference formatting and parsing")
    func movieRef() {
        let ref = EntityRef.movie(tmdbId: 550)
        #expect(ref.rawValue == "550")
        #expect(ref.entityKind == .movie)

        let parsed = EntityRef.parse("550", kind: .movie)
        #expect(parsed == ref)
        #expect(EntityRef.parse("invalid", kind: .movie) == nil)
    }

    @Test("Show reference formatting and parsing")
    func showRef() {
        let ref1 = EntityRef.show(showId: "tmdb:1396")
        #expect(ref1.rawValue == "tmdb:1396")
        #expect(ref1.entityKind == .show)

        let parsed1 = EntityRef.parse("tmdb:1396", kind: .show)
        #expect(parsed1 == ref1)

        let ref2 = EntityRef.show(showId: "tvrage:81081")
        #expect(ref2.rawValue == "tvrage:81081")
        let parsed2 = EntityRef.parse("tvrage:81081", kind: .show)
        #expect(parsed2 == ref2)

        #expect(EntityRef.parse("nosplit", kind: .show) == nil)
    }

    @Test("Season reference formatting and parsing")
    func seasonRef() {
        let ref = EntityRef.season(showId: "tmdb:1396", seasonNumber: 2)
        #expect(ref.rawValue == "tmdb:1396:s2")
        #expect(ref.entityKind == .season)

        let parsed = EntityRef.parse("tmdb:1396:s2", kind: .season)
        #expect(parsed == ref)

        #expect(EntityRef.parse("tmdb:1396", kind: .season) == nil)
        #expect(EntityRef.parse("tmdb:1396:sX", kind: .season) == nil)
    }

    @Test("Episode reference formatting and parsing")
    func episodeRef() {
        let ref = EntityRef.episode(showId: "tmdb:1396", seasonNumber: 1, episodeNumber: 5)
        #expect(ref.rawValue == "tmdb:1396:s1e5")
        #expect(ref.entityKind == .episode)

        let parsed = EntityRef.parse("tmdb:1396:s1e5", kind: .episode)
        #expect(parsed == ref)

        let complexShow = EntityRef.episode(showId: "tvrage:81081", seasonNumber: 3, episodeNumber: 12)
        #expect(complexShow.rawValue == "tvrage:81081:s3e12")
        #expect(EntityRef.parse("tvrage:81081:s3e12", kind: .episode) == complexShow)

        #expect(EntityRef.parse("tmdb:1396:s1", kind: .episode) == nil)
        #expect(EntityRef.parse("tmdb:1396:s1e", kind: .episode) == nil)
    }

    @Test("Person reference formatting and parsing")
    func personRef() {
        let ref = EntityRef.person(personId: "tmdb:32231")
        #expect(ref.rawValue == "tmdb:32231")
        #expect(ref.entityKind == .person)

        let parsed = EntityRef.parse("tmdb:32231", kind: .person)
        #expect(parsed == ref)

        let localRef = EntityRef.person(personId: "local:christopher-nolan")
        #expect(localRef.rawValue == "local:christopher-nolan")
        #expect(EntityRef.parse("local:christopher-nolan", kind: .person) == localRef)
    }

    @Test("Credit role raw value mapping")
    func creditRole() {
        #expect(CreditRole(rawValue: "actor") == .actor)
        #expect(CreditRole(rawValue: "director") == .director)
        #expect(CreditRole(rawValue: "self") == .selfRole)
        #expect(CreditRole(rawValue: "crew:Director of Photography") == .crew("Director of Photography"))
        #expect(CreditRole.crew("Gaffer").rawValue == "crew:Gaffer")
        #expect(CreditRole(rawValue: "unknown") == nil)
    }
}
