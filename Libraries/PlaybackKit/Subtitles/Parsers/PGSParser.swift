import Foundation

/// Parses PGS/SUP image subtitles, including palette and RLE bitmap decoding.
///
/// PGS is the bitmap subtitle format used on Blu-ray. Each segment carries a
/// 90 kHz timestamp, and presentation-composition segments place decoded
/// objects in video pixel coordinates (PB-2).
public struct PGSParser: SubtitleParsing {
    private struct DecodedObject {
        var width: Int
        var height: Int
        var pixels: Data
    }

    private struct Composition {
        var start: TimeInterval
        var images: [SubtitleImage]
    }

    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        var cursor = 0
        var palette: [UInt8: SubtitleColor] = [:]
        var objects: [UInt16: DecodedObject] = [:]
        var compositions: [Composition] = []

        while cursor + 13 <= data.count {
            guard data[cursor] == 0x50, data[cursor + 1] == 0x47 else {
                break
            }
            let pts = readUInt32(data, cursor + 2)
            let type = data[cursor + 10]
            let length = Int(readUInt16(data, cursor + 11))
            let payloadStart = cursor + 13
            guard payloadStart + length <= data.count else {
                throw SubtitleParseError.invalidImageData(
                    "PGS segment at \(cursor) runs past the end of the file."
                )
            }
            let payload = data.subdata(
                in: payloadStart..<(payloadStart + length)
            )

            switch type {
            case 0x14:
                parsePalette(payload, into: &palette)
            case 0x15:
                if let (id, object) = try parseObject(payload, palette: palette) {
                    objects[id] = object
                }
            case 0x16:
                let composition = parseComposition(
                    payload,
                    timestamp: TimeInterval(pts) / 90_000,
                    objects: objects
                )
                if !composition.images.isEmpty {
                    compositions.append(composition)
                }
            default:
                break
            }

            cursor = payloadStart + length
        }

        guard !compositions.isEmpty else {
            return SubtitleDocument(format: .pgs, cues: [])
        }

        var cues: [SubtitleCue] = []
        for (index, composition) in compositions.enumerated() {
            let end: TimeInterval
            if index + 1 < compositions.count {
                end = compositions[index + 1].start
            } else {
                end = composition.start + 5
            }
            guard end > composition.start else {
                continue
            }
            for (imageIndex, image) in composition.images.enumerated() {
                cues.append(
                    SubtitleCue(
                        id: index * 100 + imageIndex,
                        start: composition.start,
                        end: end,
                        content: .image(image)
                    )
                )
            }
        }

        return SubtitleDocument(format: .pgs, cues: cues)
    }

    // MARK: - Segments

    private func parsePalette(
        _ payload: Data,
        into palette: inout [UInt8: SubtitleColor]
    ) {
        guard payload.count >= 2 else {
            return
        }
        var cursor = 2
        while cursor + 5 <= payload.count {
            let index = payload[cursor]
            let y = payload[cursor + 1]
            let cr = payload[cursor + 2]
            let cb = payload[cursor + 3]
            let alpha = payload[cursor + 4]
            palette[index] = Self.color(
                y: y,
                cr: cr,
                cb: cb,
                alpha: alpha
            )
            cursor += 5
        }
    }

    private func parseObject(
        _ payload: Data,
        palette: [UInt8: SubtitleColor]
    ) throws -> (UInt16, DecodedObject)? {
        guard payload.count >= 11 else {
            return nil
        }
        let objectID = readUInt16(payload, 0)
        let sequence = payload[3]
        // 0x80 marks the first fragment, 0x40 the last. Only decode complete
        // objects; fragmented objects are skipped until a complete one arrives.
        guard sequence & 0x80 != 0, sequence & 0x40 != 0 else {
            return nil
        }

        let dataLength = Int(payload[4]) << 16
            | Int(payload[5]) << 8
            | Int(payload[6])
        let width = Int(readUInt16(payload, 7))
        let height = Int(readUInt16(payload, 9))
        guard width > 0, height > 0 else {
            return nil
        }
        let rleStart = 11
        let rleEnd = min(payload.count, rleStart + dataLength)
        guard rleStart <= rleEnd else {
            return nil
        }
        let rle = payload.subdata(in: rleStart..<rleEnd)
        let paletteIndices = try Self.decodeRLE(
            rle,
            width: width,
            height: height
        )
        let pixels = Self.rgba(
            indices: paletteIndices,
            palette: palette
        )
        return (
            objectID,
            DecodedObject(width: width, height: height, pixels: pixels)
        )
    }

    private func parseComposition(
        _ payload: Data,
        timestamp: TimeInterval,
        objects: [UInt16: DecodedObject]
    ) -> Composition {
        guard payload.count >= 11 else {
            return Composition(start: timestamp, images: [])
        }
        let objectCount = Int(payload[10])
        var cursor = 11
        var images: [SubtitleImage] = []
        for _ in 0..<objectCount {
            guard cursor + 8 <= payload.count else {
                break
            }
            let objectID = readUInt16(payload, cursor)
            let x = Int(readUInt16(payload, cursor + 4))
            let y = Int(readUInt16(payload, cursor + 6))
            cursor += 8

            guard let object = objects[objectID] else {
                continue
            }
            images.append(
                SubtitleImage(
                    width: object.width,
                    height: object.height,
                    pixels: object.pixels,
                    x: x,
                    y: y
                )
            )
        }
        return Composition(start: timestamp, images: images)
    }

    // MARK: - RLE and palette

    /// Decodes PGS run-length data into one palette index per pixel.
    static func decodeRLE(
        _ data: Data,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var x = 0
        var y = 0
        var cursor = 0

        func advance(_ count: Int) {
            for _ in 0..<count {
                if x < width && y < height {
                    pixels[y * width + x] = 0
                }
                x += 1
                if x >= width {
                    x = 0
                    y += 1
                }
            }
        }

        while cursor < data.count {
            let value = data[cursor]
            cursor += 1

            if value == 0 {
                guard cursor < data.count else {
                    break
                }
                let code = data[cursor]
                cursor += 1
                switch code {
                case 0:
                    x = 0
                    y += 1
                case 1:
                    return pixels
                case 2:
                    guard cursor + 1 < data.count else {
                        return pixels
                    }
                    let skip = Int(data[cursor]) << 8 | Int(data[cursor + 1])
                    cursor += 2
                    advance(skip)
                default:
                    break
                }
            } else {
                guard cursor < data.count else {
                    return pixels
                }
                var run = Int(data[cursor])
                cursor += 1
                if run == 0 {
                    run = 256
                }
                for _ in 0..<run {
                    if x < width && y < height {
                        pixels[y * width + x] = value
                    }
                    x += 1
                    if x >= width {
                        x = 0
                        y += 1
                    }
                }
            }
        }
        return pixels
    }

    private static func rgba(
        indices: [UInt8],
        palette: [UInt8: SubtitleColor]
    ) -> Data {
        var data = Data(capacity: indices.count * 4)
        for index in indices {
            let color = palette[index]
                ?? (index == 0
                    ? SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0)
                    : .white)
            let alpha = color.alpha
            data.append(UInt8((color.red * alpha * 255).rounded()))
            data.append(UInt8((color.green * alpha * 255).rounded()))
            data.append(UInt8((color.blue * alpha * 255).rounded()))
            data.append(UInt8((alpha * 255).rounded()))
        }
        return data
    }

    /// Converts the PGS limited-range YCbCr palette entry to RGB.
    static func color(
        y: UInt8,
        cr: UInt8,
        cb: UInt8,
        alpha: UInt8
    ) -> SubtitleColor {
        let c = Double(y) - 16
        let d = Double(cb) - 128
        let e = Double(cr) - 128
        let red = (298 * c + 409 * e + 128) / 256
        let green = (298 * c - 100 * d - 208 * e + 128) / 256
        let blue = (298 * c + 516 * d + 128) / 256
        return SubtitleColor(
            red: min(1, max(0, red / 255)),
            green: min(1, max(0, green / 255)),
            blue: min(1, max(0, blue / 255)),
            alpha: Double(alpha) / 255
        )
    }

    // MARK: - Little-endian helpers

    private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }
}
