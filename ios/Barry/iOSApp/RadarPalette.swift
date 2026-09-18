//  RadarPalette.swift
//  Barry — iOS
//
//  Barry's own radar colors. RainViewer serves every request in its
//  Universal Blue palette, where each dBZ has one exact color, so an
//  unsmoothed tile can be read back to dBZ pixel by pixel and repainted:
//  rain in soft blues from light to deep, a hard break to orange at 45 dBZ
//  where an echo stops being just rain, red from the low fifties, magenta
//  from 60 where hail becomes likely, a white core above that. Pixels that
//  are not in the table (snow, in RainViewer's own snow colors) pass through
//  untouched.

import CoreGraphics
import UIKit

enum RadarPalette {
    /// Universal Blue: packed RGBA (non-premultiplied) -> dBZ.
    private static let universalBlue: [UInt32: Int] = [0x63615914: -10, 0x66635A19: -9, 0x69665C1E: -8, 0x6C685D24: -7, 0x6F6B5F29: -6, 0x726E612E: -5, 0x75706234: -4, 0x78736439: -3, 0x7C75653E: -2, 0x7F786744: -1, 0x827B6949: 0, 0x857D6A4E: 1, 0x88806C54: 2, 0x8B826D59: 3, 0x8E856F5E: 4, 0x92887164: 5, 0x9E93756E: 6, 0xAA9E7978: 7, 0xB6A97E82: 8, 0xC2B4828C: 9, 0xCEC08796: 10, 0xD2C48BA0: 11, 0xD6C88FAA: 12, 0xDACC93B4: 13, 0xDED097BE: 14, 0x88DDEEFF: 15, 0x6CD1EBFF: 16, 0x51C5E8FF: 17, 0x36BAE5FF: 18, 0x1BAEE2FF: 19, 0x00A3E0FF: 20, 0x009AD5FF: 21, 0x0091CAFF: 22, 0x0088BFFF: 23, 0x007FB4FF: 24, 0x0077AAFF: 25, 0x0070A3FF: 26, 0x00699CFF: 27, 0x006295FF: 28, 0x005B8EFF: 29, 0x005588FF: 30, 0x005180FF: 31, 0x004E78FF: 32, 0x004A70FF: 33, 0x004768FF: 34, 0xFFEE00FF: 35, 0xFFE000FF: 36, 0xFFD200FF: 37, 0xFFC500FF: 38, 0xFFB700FF: 39, 0xFFAA00FF: 40, 0xFF9F00FF: 41, 0xFF9500FF: 42, 0xFF8B00FF: 43, 0xFF8100FF: 44, 0xFF4400FF: 45, 0xF23600FF: 46, 0xE62800FF: 47, 0xD91B00FF: 48, 0xCD0D00FF: 49, 0xC10000FF: 50, 0xA80000FF: 51, 0x8F0000FF: 52, 0x760000FF: 53, 0x5D0000FF: 54, 0xFFAAFFFF: 55, 0xFF9FFFFF: 56, 0xFF95FFFF: 57, 0xFF8BFFFF: 58, 0xFF81FFFF: 59, 0xFF77FFFF: 60, 0xFF6CFFFF: 61, 0xFF62FFFF: 62, 0xFF58FFFF: 63, 0xFF4EFFFF: 64, 0xFFFFFFFF: 65, 0x00FF00FF: 75, 0xCEFFFF0C: -9, 0xCDFFFF19: -8, 0xCCFFFF26: -7, 0xCBFFFF33: -6, 0xCBFFFF3F: -5, 0xCAFFFF4C: -4, 0xC9FFFF59: -3, 0xC8FFFF66: -2, 0xC7FFFF72: -1, 0xC7FFFF7F: 0, 0xC6FFFF8C: 1, 0xC5FFFF99: 2, 0xC4FFFFA5: 3, 0xC3FFFFB2: 4, 0xC3FFFFBF: 5, 0xC2FFFFCC: 6, 0xC1FFFFD8: 7, 0xC0FFFFE5: 8, 0xBFFFFFF2: 9, 0xBFFFFFFF: 10, 0xB8F8FFFF: 11, 0xB2F2FFFF: 12, 0xABEBFFFF: 13, 0xA5E5FFFF: 14, 0x9FDFFFFF: 15, 0x98D8FFFF: 16, 0x92D2FFFF: 17, 0x8BCBFFFF: 18, 0x85C5FFFF: 19, 0x7FBFFFFF: 20, 0x78B8FFFF: 21, 0x72B2FFFF: 22, 0x6BABFFFF: 23, 0x65A5FFFF: 24, 0x5F9FFFFF: 25, 0x5B9BFFFF: 26, 0x5898FFFF: 27, 0x5595FFFF: 28, 0x5292FFFF: 29, 0x4F8FFFFF: 30, 0x4B8BFFFF: 31, 0x4888FFFF: 32, 0x4585FFFF: 33, 0x4282FFFF: 34, 0x3F7FFFFF: 35, 0x3B7BFFFF: 36, 0x3878FFFF: 37, 0x3575FFFF: 38, 0x3272FFFF: 39, 0x2F6FFFFF: 40, 0x2B6BFFFF: 41, 0x2868FFFF: 42, 0x2565FFFF: 43, 0x2262FFFF: 44, 0x1F5FFFFF: 45, 0x1B5BFFFF: 46, 0x1858FFFF: 47, 0x1555FFFF: 48, 0x1252FFFF: 49, 0x0F4FFFFF: 50, 0x0C4BFFFF: 51, 0x0948FFFF: 52, 0x0645FFFF: 53, 0x0242FFFF: 54, 0x003FFFFF: 55, 0x003BFFFF: 56, 0x0038FFFF: 57, 0x0035FFFF: 58, 0x0032FFFF: 59, 0x002FFFFF: 60, 0x002BFFFF: 61, 0x0028FFFF: 62, 0x0025FFFF: 63, 0x0022FFFF: 64, 0x001FFFFF: 65, 0x001BFFFF: 66, 0x0018FFFF: 67, 0x0015FFFF: 68, 0x0012FFFF: 69, 0x000FFFFF: 70, 0x000CFFFF: 71, 0x0009FFFF: 72, 0x0006FFFF: 73, 0x0002FFFF: 74, 0x0000FFFF: 75]

    /// The same table grouped by alpha, for tiles that arrive premultiplied.
    private static let byAlpha: [UInt8: [(UInt32, Int)]] = {
        var d: [UInt8: [(UInt32, Int)]] = [:]
        for (k, v) in universalBlue { d[UInt8(k & 0xFF), default: []].append((k, v)) }
        return d
    }()

    /// Barry's colors per dBZ, premultiplied RGBA for the output bitmap.
    private static let lut: [UInt32] = (0..<128).map { i in pack(color(dBZ: i - 32)) }

    static func color(dBZ d: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        func mix(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double), _ t: Double)
            -> (r: Double, g: Double, b: Double, a: Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t, a.3 + (b.3 - a.3) * t)
        }
        switch d {
        case ..<5:    return (0, 0, 0, 0)
        case 5..<15:  return mix((0.62, 0.80, 1.00, 0.30), (0.45, 0.68, 0.98, 0.55), Double(d - 5) / 10)
        case 15..<25: return mix((0.45, 0.68, 0.98, 0.55), (0.28, 0.52, 0.94, 0.72), Double(d - 15) / 10)
        case 25..<35: return mix((0.28, 0.52, 0.94, 0.72), (0.18, 0.36, 0.86, 0.84), Double(d - 25) / 10)
        case 35..<45: return mix((0.18, 0.36, 0.86, 0.84), (0.22, 0.16, 0.66, 0.92), Double(d - 35) / 10)
        case 45..<50: return (1.00, 0.60, 0.16, 0.94)   // convective
        case 50..<55: return (0.96, 0.36, 0.12, 0.96)
        case 55..<60: return (0.84, 0.13, 0.13, 0.98)   // severe core
        case 60..<65: return (0.90, 0.16, 0.86, 1.00)   // hail likely
        default:      return (1.00, 0.86, 1.00, 1.00)   // extreme core
        }
    }

    private static func pack(_ c: (r: Double, g: Double, b: Double, a: Double)) -> UInt32 {
        // Premultiplied, byte order R G B A in memory (big-endian packing).
        let a = UInt32((c.a * 255).rounded())
        let r = UInt32((c.r * c.a * 255).rounded()), g = UInt32((c.g * c.a * 255).rounded()), b = UInt32((c.b * c.a * 255).rounded())
        return r << 24 | g << 16 | b << 8 | a
    }

    /// dBZ for one source pixel, or nil when it is not a Universal Blue rain color.
    private static func dBZ(r: UInt8, g: UInt8, b: UInt8, a: UInt8, premultiplied: Bool) -> Int? {
        if a == 0 { return nil }
        let key = UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
        if let d = universalBlue[key] { return d }
        guard premultiplied || a < 255, let candidates = byAlpha[a] else { return nil }
        // Nearest color with the same alpha: premultiplication moved the RGB.
        let af = Double(a) / 255
        var best: (Int, Int)? = nil
        for (k, d) in candidates {
            let kr = Double((k >> 24) & 0xFF) * af, kg = Double((k >> 16) & 0xFF) * af, kb = Double((k >> 8) & 0xFF) * af
            let dist = Int(abs(kr - Double(r)) + abs(kg - Double(g)) + abs(kb - Double(b)))
            if best == nil || dist < best!.0 { best = (dist, d) }
        }
        return (best?.0 ?? 999) <= 12 ? best?.1 : nil
    }

    /// Repaint a RainViewer tile. Returns the original data when the image
    /// cannot be read, so the map never goes blank.
    static func recolor(_ png: Data) -> Data {
        guard let src = UIImage(data: png)?.cgImage, let provider = src.dataProvider,
              let raw = provider.data, src.bitsPerPixel == 32, src.bitsPerComponent == 8 else { return png }
        let w = src.width, h = src.height, rowBytes = src.bytesPerRow
        let alphaInfo = src.alphaInfo
        let premultiplied = alphaInfo == .premultipliedLast || alphaInfo == .premultipliedFirst
        let alphaFirst = alphaInfo == .first || alphaInfo == .premultipliedFirst || alphaInfo == .noneSkipFirst
        let littleEndian = src.bitmapInfo.contains(.byteOrder32Little)
        guard let base = CFDataGetBytePtr(raw) else { return png }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let row = base + y * rowBytes
                for x in 0..<w {
                    let p = row + x * 4
                    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
                    // Memory order for the common PNG cases.
                    if littleEndian {
                        if alphaFirst { b = p[0]; g = p[1]; r = p[2]; a = p[3] } else { a = p[0]; b = p[1]; g = p[2]; r = p[3] }
                    } else {
                        if alphaFirst { a = p[0]; r = p[1]; g = p[2]; b = p[3] } else { r = p[0]; g = p[1]; b = p[2]; a = p[3] }
                    }
                    let o = (y * w + x) * 4
                    if let d = dBZ(r: r, g: g, b: b, a: a, premultiplied: premultiplied) {
                        let v = lut[max(0, min(127, d + 32))]
                        dst[o] = UInt8(v >> 24); dst[o + 1] = UInt8((v >> 16) & 0xFF); dst[o + 2] = UInt8((v >> 8) & 0xFF); dst[o + 3] = UInt8(v & 0xFF)
                    } else if a > 0 {
                        // Not rain in the table (snow): keep it, premultiplied.
                        let af = Int(a)
                        let pr = premultiplied ? Int(r) : Int(r) * af / 255
                        let pg = premultiplied ? Int(g) : Int(g) * af / 255
                        let pb = premultiplied ? Int(b) : Int(b) * af / 255
                        dst[o] = UInt8(pr); dst[o + 1] = UInt8(pg); dst[o + 2] = UInt8(pb); dst[o + 3] = a
                    }
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: info.rawValue),
              let dstBase = ctx.data else { return png }
        out.withUnsafeBytes { src in dstBase.copyMemory(from: src.baseAddress!, byteCount: w * h * 4) }
        guard let img = ctx.makeImage() else { return png }
        return UIImage(cgImage: img).pngData() ?? png
    }
}
