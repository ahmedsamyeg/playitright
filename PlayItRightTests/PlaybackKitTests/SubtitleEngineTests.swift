import Foundation
import Metal
import Testing
@testable import PlaybackKit

// MARK: - Fixtures

private let srtSample = """
1
00:00:01,000 --> 00:00:03,500
Hello <i>world</i>

2
00:00:04,250 --> 00:00:06,000
Second line
continued
"""

private let webVTTSample = """
WEBVTT

1
00:00:00.500 --> 00:00:02.000 align:start position:10%
Hello <b>VTT</b>

00:03.000 --> 00:04.000
No id
"""

private let assSample = """
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, Bold, Italic, Alignment, MarginV
Style: Forced,Arial,48,&H00FFFFFF,&H00000000,&H00000000,1,0,2,0
Style: Default,Arial,48,&H00FFFFFF,&H00000000,&H00000000,0,0,2,0

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Forced,,0,0,0,,{\\an8\\pos(960,100)}Top sign
Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,Hello, world
"""

// MARK: - PGS helpers

private func be16(_ value: UInt16) -> [UInt8] {
    [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func be32(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
}

private func pgsSegment(type: UInt8, pts: UInt32, payload: Data) -> Data {
    var data = Data([0x50, 0x47])
    data.append(contentsOf: be32(pts))
    data.append(contentsOf: be32(0))
    data.append(type)
    data.append(contentsOf: be16(UInt16(payload.count)))
    data.append(payload)
    return data
}

private func pgsSample() -> Data {
    let palette = Data([0, 0, 2, 235, 128, 128, 255])

    let rle: [UInt8] = [
        2, 4, 0, 0, // row 0: four pixels of palette index 2
        2, 4, 0, 0, // row 1
        0, 1 // end of object
    ]
    var object = Data([0x00, 0x01, 0, 0xC0])
    let length = UInt32(rle.count)
    object.append(contentsOf: [
        UInt8((length >> 16) & 0xFF),
        UInt8((length >> 8) & 0xFF),
        UInt8(length & 0xFF)
    ])
    object.append(contentsOf: be16(4)) // width
    object.append(contentsOf: be16(2)) // height
    object.append(contentsOf: rle)

    var composition = Data()
    composition.append(contentsOf: be16(1_920))
    composition.append(contentsOf: be16(1_080))
    composition.append(0x10) // frame rate
    composition.append(contentsOf: be16(1)) // composition number
    composition.append(0x80) // epoch start
    composition.append(0) // palette update
    composition.append(0) // palette id
    composition.append(1) // object count
    composition.append(contentsOf: [
        0x00, 0x01, // object id
        0x00, // window id
        0x00, // flags
        0x00, 0x64, // x = 100
        0x00, 0x32 // y = 50
    ])

    var data = Data()
    data.append(pgsSegment(type: 0x14, pts: 0, payload: palette))
    data.append(pgsSegment(type: 0x15, pts: 0, payload: object))
    data.append(pgsSegment(type: 0x16, pts: 90_000, payload: composition))
    data.append(pgsSegment(type: 0x80, pts: 0, payload: Data()))
    return data
}

// MARK: - Tests

@Suite("SubtitleEngine Tests")
struct SubtitleEngineTests {
    @Test("SRT parses timestamps, tags, and multi-line cues")
    func srtParsing() throws {
        let engine = try SubtitleEngine(
            data: Data(srtSample.utf8),
            format: .srt
        )
        #expect(engine.document.cues.count == 2)

        let first = try #require(engine.document.cues.first)
        #expect(first.id == 1)
        #expect(abs(first.start - 1.0) < 0.000_1)
        #expect(abs(first.end - 3.5) < 0.000_1)
        #expect(first.text == "Hello world")
        #expect(first.alignment == .bottomCenter)

        let second = engine.document.cues[1]
        #expect(abs(second.start - 4.25) < 0.000_1)
        #expect(second.text == "Second line\ncontinued")
    }

    @Test("WebVTT parses header, ids, settings, and short timestamps")
    func webVTTParsing() throws {
        let engine = try SubtitleEngine(
            data: Data(webVTTSample.utf8),
            format: .webvtt
        )
        #expect(engine.document.cues.count == 2)

        let first = engine.document.cues[0]
        #expect(first.text == "Hello VTT")
        #expect(abs(first.start - 0.5) < 0.000_1)
        #expect(first.alignment == .bottomLeft)
        let position = try #require(first.position)
        #expect(abs(position.x - 0.1) < 0.000_1)
        #expect(abs(position.y - 0.9) < 0.000_1)

        let second = engine.document.cues[1]
        #expect(abs(second.start - 3.0) < 0.000_1)
        #expect(second.text == "No id")
    }

    @Test("ASS parses dialogue, styles, overrides, and commas in text")
    func assParsing() throws {
        let engine = try SubtitleEngine(
            data: Data(assSample.utf8),
            format: .ass
        )
        #expect(engine.document.cues.count == 2)
        #expect(engine.document.playResX == 1_920)
        #expect(engine.document.playResY == 1_080)

        let first = engine.document.cues[0]
        #expect(first.text == "Top sign")
        #expect(first.isForced)
        #expect(first.alignment == .topCenter)
        #expect(first.isBold)
        let position = try #require(first.position)
        #expect(abs(position.x - 0.5) < 0.000_1)
        #expect(abs(position.y - (100.0 / 1_080.0)) < 0.000_1)

        let second = engine.document.cues[1]
        #expect(second.text == "Hello, world")
        #expect(!second.isForced)
    }

    @Test("PGS bitmaps are RLE-decoded, palettized, and positioned")
    func pgsParsing() throws {
        let engine = try SubtitleEngine(
            data: pgsSample(),
            format: .pgs
        )
        #expect(engine.document.cues.count == 1)
        #expect(engine.isImageBased)

        let cue = try #require(engine.document.cues.first)
        #expect(abs(cue.start - 1.0) < 0.000_1)
        #expect(abs(cue.end - 6.0) < 0.000_1)

        let image = try #require(cue.image)
        #expect(image.width == 4)
        #expect(image.height == 2)
        #expect(image.x == 100)
        #expect(image.y == 50)
        #expect(image.pixels.count == 4 * 2 * 4)

        // Palette index 2 is neutral white in the limited-range conversion.
        #expect(Array(image.pixels.prefix(4)) == [255, 255, 255, 255])
    }

    @Test("Forced-only filtering toggles without changing the document")
    func forcedFiltering() throws {
        var engine = try SubtitleEngine(
            data: Data(assSample.utf8),
            format: .ass
        )
        #expect(engine.cues(at: 2).count == 1)
        #expect(engine.cues(at: 5).count == 1)

        let forced = engine.setForcedOnly(true)
        #expect(forced)
        #expect(engine.cues(at: 2).count == 1)
        #expect(engine.cues(at: 5).isEmpty)
        #expect(engine.forcedCues.count == 1)

        engine.setForcedOnly(false)
        #expect(engine.cues(at: 5).count == 1)
        #expect(engine.document.cues.count == 2)
    }

    @Test("Cue selection tolerates one frame of timing error")
    func frameTolerance() throws {
        let document = SubtitleDocument(
            format: .srt,
            cues: [
                SubtitleCue(
                    id: 1,
                    start: 1,
                    end: 2,
                    content: .text("Cue")
                )
            ]
        )
        let engine = SubtitleEngine(
            document: document,
            frameDuration: 1.0 / 24.0
        )
        #expect(engine.cues(at: 0.97).count == 1)
        #expect(engine.cues(at: 0.95).isEmpty)
        #expect(engine.cues(at: 2.04).count == 1)
        #expect(engine.cues(at: 2.06).isEmpty)
    }

    @Test("Styling controls clamp font scale, offset, and opacity")
    func stylingControls() {
        var engine = SubtitleEngine(
            document: SubtitleDocument(format: .srt, cues: [])
        )
        let largest = engine.adjustFontSize(by: 20)
        #expect(largest == 2)
        let smallest = engine.adjustFontSize(by: -100)
        #expect(smallest == 0.5)
        let highest = engine.adjustPosition(by: 2)
        #expect(highest == 0.5)
        let lowest = engine.adjustPosition(by: -2)
        #expect(lowest == -0.5)
        let opaque = engine.setOpacity(2)
        #expect(opaque == 1)
        let transparent = engine.setOpacity(-1)
        #expect(transparent == 0)
    }

    @Test("Unsupported subtitle formats fail with a clear error")
    func unsupportedFormat() {
        var failure: Error?
        do {
            _ = try SubtitleEngine(
                data: Data(),
                format: .other
            )
        } catch {
            failure = error
        }
        #expect(
            failure as? SubtitleParseError
                == .unsupportedFormat(SubtitleFormat.other.rawValue)
        )
    }

    @Test("The Metal renderer produces a transparent overlay texture")
    func metalOverlay() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            return
        }
        let renderer = try MetalSubtitleRenderer()
        let document = SubtitleDocument(
            format: .srt,
            cues: [
                SubtitleCue(
                    id: 1,
                    start: 0,
                    end: 1,
                    content: .text("Subtitle")
                )
            ]
        )
        let engine = SubtitleEngine(document: document)
        let plan = engine.renderPlan(
            at: 0.5,
            canvasWidth: 320,
            canvasHeight: 180
        )
        let texture = try renderer.render(plan)
        #expect(texture.width == 320)
        #expect(texture.height == 180)
        #expect(texture.pixelFormat == .rgba8Unorm)
    }
}
