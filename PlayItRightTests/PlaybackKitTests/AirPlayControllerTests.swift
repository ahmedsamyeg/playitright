import AVFoundation
import AVKit
import Foundation
import Testing
@testable import PlaybackKit

@Suite("AirPlayController Tests")
struct AirPlayControllerTests {
    @Test("Routes classify HomePod, Apple TV, and headphones")
    func routeClassification() {
        let homePod = AirPlayRoute(
            name: "Living Room HomePod",
            portType: .airPlay
        )
        #expect(homePod.kind == .homePod)
        #expect(homePod.audioSetup == .homePod)
        #expect(homePod.isAirPlay)
        #expect(!homePod.isVideoRoute)

        let appleTV = AirPlayRoute(
            name: "Bedroom Apple TV",
            portType: .airPlay
        )
        #expect(appleTV.kind == .appleTV)
        #expect(appleTV.isVideoRoute)
        #expect(appleTV.audioSetup == .speakers)

        let generic = AirPlayRoute(name: "Speaker", portType: .airPlay)
        #expect(generic.kind == .airPlay)

        let headphones = AirPlayRoute(
            name: "Headphones",
            portType: .headphones
        )
        #expect(headphones.kind == .headphones)
        #expect(headphones.audioSetup == .headphones)
    }

    @Test("A HomePod route change updates SinkProfile and triggers re-plan")
    @MainActor
    func homePodRouteChangeUpdatesProfile() async throws {
        final class Box: @unchecked Sendable {
            var route = AirPlayRoute(
                name: "TV Speakers",
                portType: .builtInSpeaker
            )
            var routes: [AirPlayRoute] = []
            var replanned: [SinkProfile] = []
        }

        let center = NotificationCenter()
        let box = Box()
        let observation = SinkObservation(
            display: DisplayCapabilities(
                width: 3_840,
                height: 2_160,
                maxRefreshRate: 60
            ),
            audioSetup: .stereo,
            routeName: "TV Speakers"
        )
        let manager = SinkProfileManager(
            notificationCenter: center,
            observation: { observation }
        )
        let controller = AirPlayController(
            sinkManager: manager,
            notificationCenter: center,
            routeProvider: { box.route }
        )

        controller.onRouteChange = { route in
            box.routes.append(route)
        }
        controller.onReplan = { profile in
            box.replanned.append(profile)
        }

        #expect(manager.profile.audio.setup == .stereo)
        #expect(controller.currentRoute.kind == .builtIn)
        #expect(box.replanned.isEmpty)

        box.route = AirPlayRoute(
            name: "Living Room HomePod",
            portType: .airPlay
        )
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        for _ in 0..<200 where box.replanned.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(controller.routeChangeCount == 1)
        #expect(controller.currentRoute.kind == .homePod)
        #expect(controller.currentRoute.name == "Living Room HomePod")

        #expect(manager.profile.audio.setup == .homePod)
        #expect(manager.profile.audio.maxChannels == 2)
        #expect(manager.profile.audio.supportsAtmos)
        #expect(manager.profile.audio.canPassthrough(.eac3))
        #expect(manager.profile.audio.routeName == "Living Room HomePod")

        let replanned = try #require(box.replanned.last)
        #expect(replanned.audio.setup == .homePod)
        #expect(replanned.audio.supportsAtmos)
        #expect(box.routes.last?.kind == .homePod)
    }

    @Test("A user audio declaration still wins over the observed route")
    @MainActor
    func userOverrideWinsOverAirPlayRoute() {
        let observation = SinkObservation(
            display: DisplayCapabilities(width: 3_840, height: 2_160),
            audioSetup: .stereo,
            routeName: "TV Speakers"
        )
        let manager = SinkProfileManager(
            overrides: SinkOverrides(audio: .receiverAtmos),
            notificationCenter: NotificationCenter(),
            observation: { observation }
        )
        let controller = AirPlayController(
            sinkManager: manager,
            notificationCenter: NotificationCenter(),
            routeProvider: {
                AirPlayRoute(name: "HomePod", portType: .airPlay)
            }
        )

        controller.refresh()

        #expect(controller.currentRoute.kind == .homePod)
        #expect(manager.profile.audio.setup == .receiverAtmos)
        #expect(manager.profile.declaredAudio == .receiverAtmos)
        #expect(manager.profile.audio.routeName == "HomePod")
    }

    @Test("The route picker prioritizes video devices")
    @MainActor
    func routePickerConfiguration() {
        let manager = SinkProfileManager(
            notificationCenter: NotificationCenter(),
            observation: {
                SinkObservation(
                    display: DisplayCapabilities(),
                    audioSetup: .stereo,
                    routeName: "TV Speakers"
                )
            }
        )
        let controller = AirPlayController(
            sinkManager: manager,
            notificationCenter: NotificationCenter(),
            routeProvider: {
                AirPlayRoute(name: "TV Speakers", portType: .builtInSpeaker)
            }
        )

        let picker = controller.makeRoutePickerView()
        #expect(picker.prioritizesVideoDevices)

        let configured = AirPlayController(
            sinkManager: manager,
            notificationCenter: NotificationCenter(),
            routeProvider: {
                AirPlayRoute(name: "TV Speakers", portType: .builtInSpeaker)
            }
        ).makeRoutePickerView()
        #expect(configured.prioritizesVideoDevices)
    }
}
