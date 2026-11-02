import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

@Suite("SinkProfile Tests")
struct SinkProfileTests {
    @Test("System defaults produce a conservative SDR stereo profile")
    @MainActor
    func systemDefaults() {
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
            notificationCenter: NotificationCenter(),
            observation: { observation }
        )

        #expect(manager.profile.display.supportsSDR)
        #expect(manager.profile.display.supportsHDR10 == false)
        #expect(manager.profile.display.supportsDolbyVision == false)
        #expect(manager.profile.display.is4K)
        #expect(manager.profile.audio.setup == .stereo)
        #expect(manager.profile.audio.maxChannels == 2)
        #expect(manager.profile.audio.supportsAtmos == false)
        #expect(manager.profile.hasUserOverrides == false)
    }

    @Test("User overrides take precedence over observed capabilities")
    @MainActor
    func userOverridesWin() {
        let observation = SinkObservation(
            display: DisplayCapabilities(
                width: 1_920,
                height: 1_080,
                maxRefreshRate: 60
            ),
            audioSetup: .stereo,
            routeName: "TV Speakers"
        )
        let manager = SinkProfileManager(
            overrides: SinkOverrides(
                display: .dolbyVision,
                audio: .receiverAtmos
            ),
            notificationCenter: NotificationCenter(),
            observation: { observation }
        )

        #expect(manager.profile.display.supportsSDR)
        #expect(manager.profile.display.supportsHDR10)
        #expect(manager.profile.display.supportsHLG)
        #expect(manager.profile.display.supportsDolbyVision)
        #expect(manager.profile.display.maxHDRFormat == .dolbyVision8)
        #expect(manager.profile.display.width == 1_920)
        #expect(manager.profile.display.height == 1_080)

        #expect(manager.profile.audio.setup == .receiverAtmos)
        #expect(manager.profile.audio.maxChannels == 8)
        #expect(manager.profile.audio.supportsAtmos)
        #expect(manager.profile.audio.canPassthrough(.eac3))
        #expect(manager.profile.audio.canPassthrough(.aac) == false)
        #expect(manager.profile.declaredDisplay == .dolbyVision)
        #expect(manager.profile.declaredAudio == .receiverAtmos)
        #expect(manager.profile.hasUserOverrides)

        manager.clearOverrides()
        #expect(manager.profile.audio.setup == .stereo)
        #expect(manager.profile.display.supportsDolbyVision == false)
        #expect(manager.profile.hasUserOverrides == false)
    }

    @Test("An audio route change notification recalculates the profile")
    @MainActor
    func routeChangeRecalculates() async throws {
        final class Box: @unchecked Sendable {
            var observation: SinkObservation

            init(_ observation: SinkObservation) {
                self.observation = observation
            }
        }

        let center = NotificationCenter()
        let box = Box(
            SinkObservation(
                display: DisplayCapabilities(
                    width: 1_920,
                    height: 1_080
                ),
                audioSetup: .stereo,
                routeName: "TV Speakers"
            )
        )
        let manager = SinkProfileManager(
            notificationCenter: center,
            observation: { box.observation }
        )
        #expect(manager.profile.audio.setup == .stereo)
        let before = manager.refreshCount

        box.observation = SinkObservation(
            display: box.observation.display,
            audioSetup: .receiverAtmos,
            routeName: "Receiver"
        )
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        for _ in 0..<100 where manager.refreshCount == before {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(manager.refreshCount > before)
        #expect(manager.profile.audio.setup == .receiverAtmos)
        #expect(manager.profile.audio.supportsAtmos)
        #expect(manager.profile.audio.routeName == "Receiver")
    }

    @Test("Declared display capabilities map to the expected HDR support")
    func declaredDisplayCapabilities() {
        let sdr = DisplayCapabilities.declared(.sdr)
        #expect(sdr.supportsSDR)
        #expect(sdr.supportsHDR10 == false)

        let hdr10 = DisplayCapabilities.declared(.hdr10)
        #expect(hdr10.supportsHDR10)
        #expect(hdr10.supportsDolbyVision == false)
        #expect(hdr10.maxHDRFormat == .hdr10)

        let hlg = DisplayCapabilities.declared(.hlg)
        #expect(hlg.supportsHLG)
        #expect(hlg.maxHDRFormat == .hlg)

        let dovi = DisplayCapabilities.declared(.dolbyVision)
        #expect(dovi.supportsDolbyVision)
        #expect(dovi.maxHDRFormat == .dolbyVision8)
    }

    @Test("Audio setup capabilities reflect the declared receiver")
    func declaredAudioCapabilities() {
        let ac3 = AudioCapabilities.declared(.receiverAC3)
        #expect(ac3.maxChannels == 6)
        #expect(ac3.supportsAtmos == false)
        #expect(ac3.canPassthrough(.ac3))
        #expect(ac3.canPassthrough(.eac3))

        let atmos = AudioCapabilities.declared(.receiverAtmos)
        #expect(atmos.maxChannels == 8)
        #expect(atmos.supportsAtmos)
        #expect(atmos.canPassthrough(.ac3))
        #expect(atmos.canPassthrough(.eac3))

        let stereo = AudioCapabilities.declared(.stereo)
        #expect(stereo.maxChannels == 2)
        #expect(stereo.canPassthrough(.ac3) == false)
    }
}
