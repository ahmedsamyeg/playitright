import Foundation
import Testing
@testable import PlayItRightStoreKit

@MainActor
private final class FakeEntitlement: ProEntitlementReading {
    var isProUnlocked: Bool

    init(isProUnlocked: Bool) {
        self.isProUnlocked = isProUnlocked
    }
}

private let now = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
private func makeGate(
    pro: Bool,
    store: InMemoryProUpsellStateStore = InMemoryProUpsellStateStore(),
    now: Date = now
) -> ProGate {
    ProGate(
        entitlement: FakeEntitlement(isProUnlocked: pro),
        clock: StaticEntitlementClock(now: now),
        state: store
    )
}

@Suite("ProGate Tests")
struct ProGateTests {
    @Test("Free includes the first source and gates the second")
    @MainActor
    func secondSourceGate() {
        let gate = makeGate(pro: false)

        #expect(gate.evaluate(.addSource(existingSourceCount: 0)) == .allowed)

        let second = gate.evaluate(.addSource(existingSourceCount: 1))
        #expect(!second.isAllowed)
        #expect(second.upsell?.feature == .additionalSource)
        #expect(second.explanation?.contains("one source") == true)
    }

    @Test("Pro adds unlimited sources")
    @MainActor
    func proSources() {
        let gate = makeGate(pro: true)
        #expect(gate.evaluate(.addSource(existingSourceCount: 4)) == .allowed)
    }

    @Test("HDR10, HLG, Dolby Vision, and Atmos stay free")
    @MainActor
    func qualityFeaturesStayFree() {
        let gate = makeGate(pro: false)

        let hdr10 = gate.evaluate(
            .playback(
                ProMediaProfile(
                    videoCodec: .hevc,
                    audioCodec: .eac3,
                    hdr: .hdr10,
                    channels: 8,
                    isAtmos: true
                )
            )
        )
        #expect(hdr10 == .allowed)

        let dovi = gate.evaluate(
            .playback(
                ProMediaProfile(
                    videoCodec: .hevc,
                    audioCodec: .ac3,
                    hdr: .dolbyVision,
                    channels: 6
                )
            )
        )
        #expect(dovi == .allowed)

        let hlg = gate.evaluate(
            .playback(
                ProMediaProfile(
                    videoCodec: .hevc,
                    audioCodec: .atmos,
                    hdr: .hlg,
                    channels: 8,
                    isAtmos: true
                )
            )
        )
        #expect(hlg == .allowed)

        // Plain 5.1 E-AC-3 is free too.
        let eac3 = gate.evaluate(
            .playback(
                ProMediaProfile(
                    videoCodec: .h264,
                    audioCodec: .eac3,
                    channels: 6
                )
            )
        )
        #expect(eac3 == .allowed)
    }

    @Test("DTS and TrueHD trigger the HD-audio upsell")
    @MainActor
    func dtsGate() {
        let gate = makeGate(pro: false)

        let dts = gate.evaluate(
            .playback(
                ProMediaProfile(
                    videoCodec: .h264,
                    audioCodec: .dts,
                    channels: 6
                )
            )
        )
        #expect(!dts.isAllowed)
        #expect(dts.upsell?.feature == .hdAudio)
        #expect(dts.explanation?.contains("DTS") == true)

        let trueHD = gate.evaluate(
            .playback(
                ProMediaProfile(
                    videoCodec: .hevc,
                    audioCodec: .trueHD,
                    channels: 8
                )
            )
        )
        #expect(trueHD.upsell?.feature == .hdAudio)
    }

    @Test("AV1, VP9, and other extended codecs trigger the video upsell")
    @MainActor
    func extendedCodecGate() {
        let gate = makeGate(pro: false)

        for codec in [ProVideoCodec.av1, .vp9, .vvc, .mpeg2, .vc1, .divx] {
            let decision = gate.evaluate(
                .playback(
                    ProMediaProfile(
                        videoCodec: codec,
                        audioCodec: .aac,
                        hdr: .hdr10
                    )
                )
            )
            #expect(!decision.isAllowed)
            #expect(decision.upsell?.feature == .extendedVideoCodecs)
        }
    }

    @Test("24-bit audio needs Pro, 16-bit stays free")
    @MainActor
    func highBitDepthGate() {
        let gate = makeGate(pro: false)

        let sixteen = gate.evaluate(
            .playback(
                ProMediaProfile(
                    videoCodec: .hevc,
                    audioCodec: .pcm,
                    bitDepth: 16
                )
            )
        )
        #expect(sixteen == .allowed)

        let twentyFour = gate.evaluate(
            .playback(
                ProMediaProfile(
                    videoCodec: .hevc,
                    audioCodec: .pcm,
                    bitDepth: 24
                )
            )
        )
        #expect(twentyFour.upsell?.feature == .hdAudio)
    }

    @Test("Cloud drives and iCloud sync require Pro")
    @MainActor
    func cloudAndSyncGate() {
        let free = makeGate(pro: false)
        #expect(free.evaluate(.cloudDrive).upsell?.feature == .cloudDrive)
        #expect(free.evaluate(.iCloudSync).upsell?.feature == .iCloudSync)

        let pro = makeGate(pro: true)
        #expect(pro.evaluate(.cloudDrive) == .allowed)
        #expect(pro.evaluate(.iCloudSync) == .allowed)
    }

    @Test("Pro unlocks every gated request")
    @MainActor
    func proUnlocksEverything() {
        let gate = makeGate(pro: true)

        #expect(gate.evaluate(.cloudDrive) == .allowed)
        #expect(gate.evaluate(.iCloudSync) == .allowed)
        #expect(gate.evaluate(.casting) == .allowed)
        #expect(gate.evaluate(.trailers) == .allowed)
        #expect(
            gate.evaluate(
                .playback(
                    ProMediaProfile(
                        videoCodec: .av1,
                        audioCodec: .trueHD,
                        hdr: .dolbyVision,
                        channels: 8,
                        isAtmos: true,
                        bitDepth: 24
                    )
                )
            ) == .allowed
        )
    }

    @Test("The proactive sheet is limited to once per day")
    @MainActor
    func proactiveThrottle() {
        let store = InMemoryProUpsellStateStore()
        let first = makeGate(pro: false, store: store)
        #expect(first.shouldPresentProactiveUpsell())
        first.recordProactiveUpsellPresentation()

        let laterSameDay = ProGate(
            entitlement: FakeEntitlement(isProUnlocked: false),
            clock: StaticEntitlementClock(now: now.addingTimeInterval(3_600)),
            state: store
        )
        #expect(!laterSameDay.shouldPresentProactiveUpsell())

        let nextDay = ProGate(
            entitlement: FakeEntitlement(isProUnlocked: false),
            clock: StaticEntitlementClock(now: now.addingTimeInterval(86_400)),
            state: store
        )
        #expect(nextDay.shouldPresentProactiveUpsell())
    }

    @Test("Pro never shows an upsell")
    @MainActor
    func proNeverUpsells() {
        let gate = makeGate(pro: true)
        #expect(!gate.shouldPresentProactiveUpsell())
        #expect(!gate.shouldShowInlineNotice(for: .hdAudio))
    }

    @Test("Each feature shows one inline notice, then only a badge")
    @MainActor
    func inlineNoticeOncePerFeature() {
        let gate = makeGate(pro: false)

        #expect(gate.shouldShowInlineNotice(for: .hdAudio))
        gate.markInlineNoticeShown(for: .hdAudio)
        #expect(!gate.shouldShowInlineNotice(for: .hdAudio))

        // Other features keep their own notice.
        #expect(gate.shouldShowInlineNotice(for: .extendedVideoCodecs))
    }

    @Test("Expired subscribers get the same gates without losing data")
    @MainActor
    func expiredSubscriberGate() {
        let gate = makeGate(pro: false)
        let decision = gate.evaluate(
            .playback(
                ProMediaProfile(
                    videoCodec: .h264,
                    audioCodec: .aac
                )
            )
        )
        #expect(decision == .allowed)
    }
}
