import Foundation
import Testing
@testable import PlaybackKit

// MARK: - Binary fixtures

private func be16(_ value: Int) -> [UInt8] {
    [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func le16(_ value: Int) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
}

private func le32(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF)
    ]
}

private func ptsBytes(_ ticks: UInt64) -> [UInt8] {
    [
        UInt8(0x21 | ((ticks >> 29) & 0x0E)),
        UInt8((ticks >> 22) & 0xFF),
        UInt8(((ticks >> 14) & 0xFE) | 0x01),
        UInt8((ticks >> 7) & 0xFF),
        UInt8(((ticks << 1) & 0xFE) | 0x01)
    ]
}

private func pesPacket(
    pts seconds: Double,
    payload: Data
) -> Data {
    let ticks = UInt64((seconds * 90_000).rounded())
    let headerLength = 5
    let packetLength = 3 + headerLength + payload.count
    var bytes: [UInt8] = [0x00, 0x00, 0x01, 0xBD]
    bytes.append(contentsOf: be16(packetLength))
    bytes.append(contentsOf: [0x80, 0x80, UInt8(headerLength)])
    bytes.append(contentsOf: ptsBytes(ticks))
    bytes.append(contentsOf: payload)
    return Data(bytes)
}

private func dvbSegment(type: UInt8, body: [UInt8]) -> [UInt8] {
    [0x0F, type, 0x00, 0x01] + be16(body.count) + body
}

private func dvbPayload() -> Data {
    // Page composition: 3 s timeout, one region at (320, 80).
    let page: [UInt8] = [
        3, 0, 0, 1,
        0, 0,
        0x01, 0x40,
        0x00, 0x50
    ]
    // Region composition: 640 x 100.
    let region: [UInt8] = [
        0, 0, 0,
        0x02, 0x80,
        0x00, 0x64,
        0, 0, 0, 0, 0, 0
    ]

    var payload = Data([0x20])
    payload.append(contentsOf: dvbSegment(type: 0x10, body: page))
    payload.append(contentsOf: dvbSegment(type: 0x11, body: region))
    return payload
}

private func vobSubPayload() -> Data {
    var control: [UInt8] = []
    control.append(contentsOf: be16(0)) // start display date
    control.append(contentsOf: be16(0)) // next SPU offset
    control.append(contentsOf: [0x01] + be16(0)) // start display
    control.append(contentsOf: [0x03] + be16(0)) // palette
    control.append(contentsOf: [0x04] + be16(0)) // alpha
    control.append(contentsOf: [0x05]) // coordinates
    control.append(contentsOf: be16(10))
    control.append(contentsOf: be16(80))
    control.append(contentsOf: be16(20))
    control.append(contentsOf: be16(30))
    control.append(contentsOf: [0x06, 0, 0, 0, 0]) // pixel offsets
    control.append(0xFF)

    var spu: [UInt8] = []
    spu.append(contentsOf: be16(4 + control.count)) // packet size
    spu.append(contentsOf: be16(4)) // control offset
    spu.append(contentsOf: control)

    var payload = Data([0x20])
    payload.append(contentsOf: spu)
    return payload
}

private func xsubData() -> Data {
    var data = Data("XSUB".utf8)
    data.append(contentsOf: le32(1_000))
    data.append(contentsOf: le16(4))
    data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
    data.append(contentsOf: le32(4_000))
    data.append(contentsOf: le16(2))
    data.append(contentsOf: [0xCA, 0xFE])
    return data
}

// MARK: - Tests

@Suite("ExtendedSubtitle Tests")
struct ExtendedSubtitleTests {
    @Test("MicroDVD uses its declared frame rate and strips markup")
    func microDVD() throws {
        let sample = """
        {1}{1}25.000
        {0}{50}{y:i}Hello|world
        {75}{100}Second
        """
        let document = try MicroDVDParser().parse(Data(sample.utf8))

        #expect(document.format == .microDVD)
        #expect(document.cues.count == 2)

        let first = document.cues[0]
        #expect(first.start == 0)
        #expect(abs(first.end - 2) < 0.000_1)
        #expect(first.text == "Hello\nworld")
        #expect(first.isItalic)

        let second = document.cues[1]
        #expect(abs(second.start - 3) < 0.000_1)
        #expect(abs(second.end - 4) < 0.000_1)
        #expect(second.text == "Second")
    }

    @Test("MPL2 decodes tenths of seconds, line breaks, and italics")
    func mpl2() throws {
        let sample = """
        [10][30]/Hello|world
        [40][60]Second
        """
        let document = try MPL2Parser().parse(Data(sample.utf8))

        #expect(document.format == .mpl2)
        #expect(document.cues.count == 2)

        let first = document.cues[0]
        #expect(abs(first.start - 1) < 0.000_1)
        #expect(abs(first.end - 3) < 0.000_1)
        #expect(first.text == "Hello\nworld")
        #expect(first.isItalic)

        let second = document.cues[1]
        #expect(abs(second.start - 4) < 0.000_1)
        #expect(abs(second.end - 6) < 0.000_1)
        #expect(!second.isItalic)
    }

    @Test("TMP cues run until the next timestamp")
    func tmp() throws {
        let sample = """
        00:00:01:First
        00:00:03:Second|line
        00:00:07:Third
        """
        let document = try TMPParser().parse(Data(sample.utf8))

        #expect(document.format == .tmp)
        #expect(document.cues.count == 3)
        #expect(abs(document.cues[0].start - 1) < 0.000_1)
        #expect(abs(document.cues[0].end - 3) < 0.000_1)
        #expect(document.cues[1].text == "Second\nline")
        #expect(abs(document.cues[1].end - 7) < 0.000_1)
        #expect(abs(document.cues[2].end - 10) < 0.000_1)
    }

    @Test("TMPlayer TXT accepts equals separators")
    func tmplayer() throws {
        let sample = """
        00:00:02=Hello
        00:00:05=World
        """
        let document = try TMPlayerParser().parse(Data(sample.utf8))

        #expect(document.format == .txt)
        #expect(document.cues.count == 2)
        #expect(abs(document.cues[0].start - 2) < 0.000_1)
        #expect(abs(document.cues[0].end - 5) < 0.000_1)
        #expect(document.cues[1].text == "World")
    }

    @Test("Timed Text parses clock, offset, duration, and inline styling")
    func timedText() throws {
        let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body>
            <div>
              <p begin="00:00:01.500" end="00:00:03.000">Hello<br/>world</p>
              <p begin="4s" dur="2s"><span style="italic">Styled</span></p>
            </div>
          </body>
        </tt>
        """
        let document = try TimedTextParser().parse(Data(sample.utf8))

        #expect(document.format == .ttml)
        #expect(document.cues.count == 2)

        let first = document.cues[0]
        #expect(abs(first.start - 1.5) < 0.000_1)
        #expect(abs(first.end - 3) < 0.000_1)
        #expect(first.text == "Hello\nworld")

        let second = document.cues[1]
        #expect(abs(second.start - 4) < 0.000_1)
        #expect(abs(second.end - 6) < 0.000_1)
        #expect(second.text == "Styled")
        #expect(second.isItalic)
    }

    @Test("Style presets produce distinct, clamped appearances")
    func stylePresets() {
        #expect(SubtitleStylePreset.standard.appearance == SubtitleAppearance())
        #expect(SubtitleStylePreset.allCases.count == 5)

        let highContrast = SubtitleStylePreset.highContrast.appearance
        #expect(highContrast.color.red == 1)
        #expect(highContrast.color.blue == 0)
        #expect(highContrast.outlineWidth >= 4)

        let largePrint = SubtitleStylePreset.largePrint.appearance
        #expect(largePrint.fontSize > highContrast.fontSize)

        let minimal = SubtitleStylePreset.minimal.appearance
        #expect(minimal.outlineWidth == 0)
        #expect(minimal.opacity < 1)

        let cinema = SubtitleAppearance(preset: .cinema)
        #expect(cinema.fontName == "Georgia")
        #expect(cinema.color != SubtitleColor.white)
    }

    @Test("DVB subtitles extract timing, duration, and region geometry")
    func dvbSubtitles() throws {
        let data = pesPacket(pts: 2, payload: dvbPayload())
        let document = try DVBSubtitleParser().parse(data)

        #expect(document.format == .dvbsub)
        #expect(document.cues.count == 1)

        let cue = try #require(document.cues.first)
        #expect(abs(cue.start - 2) < 0.000_1)
        #expect(abs(cue.end - 5) < 0.000_1)

        let image = try #require(cue.image)
        #expect(image.width == 640)
        #expect(image.height == 100)
        #expect(image.x == 320)
        #expect(image.y == 80)
    }

    @Test("VobSub extracts SPU timing and placement")
    func vobSub() throws {
        let data = pesPacket(pts: 1, payload: vobSubPayload())
        let document = try VobSubParser().parse(data)

        #expect(document.format == .vobsub)
        #expect(document.cues.count == 1)

        let cue = try #require(document.cues.first)
        #expect(abs(cue.start - 1) < 0.000_1)
        #expect(abs(cue.end - 6) < 0.000_1)

        let image = try #require(cue.image)
        #expect(image.width == 71)
        #expect(image.height == 11)
        #expect(image.x == 10)
        #expect(image.y == 20)
    }

    @Test("XSUB chunks decode millisecond frame timestamps")
    func xsub() throws {
        let document = try XSubParser().parse(xsubData())

        #expect(document.format == .xsub)
        #expect(document.cues.count == 2)
        #expect(abs(document.cues[0].start - 1) < 0.000_1)
        #expect(abs(document.cues[0].end - 4) < 0.000_1)
        #expect(abs(document.cues[1].start - 4) < 0.000_1)
        #expect(abs(document.cues[1].end - 7) < 0.000_1)
        #expect(document.isImageBased)
    }

    @Test("The engine routes every extended format to its parser")
    func engineRouting() throws {
        let microDVD = try SubtitleEngine.parse(
            Data("{0}{25}Hello".utf8),
            format: .microDVD
        )
        #expect(microDVD.cues.count == 1)
        #expect(microDVD.format == .microDVD)

        let mpl2 = try SubtitleEngine.parse(
            Data("[0][10]Hi".utf8),
            format: .mpl2
        )
        #expect(mpl2.cues.count == 1)

        let tmp = try SubtitleEngine.parse(
            Data("00:00:01:Hi".utf8),
            format: .tmp
        )
        #expect(tmp.cues.count == 1)

        let txt = try SubtitleEngine.parse(
            Data("00:00:01=Hi".utf8),
            format: .txt
        )
        #expect(txt.cues.count == 1)

        let ttml = try SubtitleEngine.parse(
            Data("<tt><body><p begin=\"1s\" end=\"2s\">Hi</p></body></tt>".utf8),
            format: .ttml
        )
        #expect(ttml.cues.count == 1)

        let dvb = try SubtitleEngine.parse(
            pesPacket(pts: 1, payload: dvbPayload()),
            format: .dvbsub
        )
        #expect(dvb.cues.count == 1)

        let vobSub = try SubtitleEngine.parse(
            pesPacket(pts: 1, payload: vobSubPayload()),
            format: .vobsub
        )
        #expect(vobSub.cues.count == 1)

        let xsub = try SubtitleEngine.parse(xsubData(), format: .xsub)
        #expect(xsub.cues.count == 2)
    }
}
