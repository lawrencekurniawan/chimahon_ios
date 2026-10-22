import Foundation
import UIKit
import ImageIO

/// CBZ spike benchmark: generate a synthetic 24-page CBZ (realistic 1600×3000
/// JPEG pages, known content) → open archive → read every entry (inflate +
/// CRC) → byte-exact integrity vs originals → full decode + production-style
/// downsampled decode timings → memory delta.
enum CBZBench {
    static let pageCount = 24
    static let pageW = 1600
    static let pageH = 3000

    struct Verdict: Codable {
        var pass: Bool
        var pageCount: Int
        var expectedPages: Int
        var generateMs: Int
        var openMs: Int
        var firstFullDecodeMs: Int
        var avgFullDecodeMs: Int
        var maxFullDecodeMs: Int
        var avgThumbDecodeMs: Int
        var integrityOK: Bool
        var decodeFailures: Int
        var dimsOK: Bool
        var fullDimsSample: String
        var thumbDimsSample: String
        var rssDeltaMB: Double
        var cbzBytes: Int
        var error: String?
    }

    // MARK: Fixture

    static func makePageImage(index: Int) -> UIImage {
        let size = CGSize(width: pageW, height: pageH)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1   // default = screen scale (3x on sim) → would render 4800×9000
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        return renderer.image { ctx in
            let c = ctx.cgContext
            // background gradient (varies per page)
            let colors = [UIColor(white: 0.12 + Double(index % 5) * 0.04, alpha: 1).cgColor,
                          UIColor(white: 0.28 + Double(index % 7) * 0.03, alpha: 1).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
                c.drawLinearGradient(grad, start: .zero,
                                     end: CGPoint(x: 0, y: pageH), options: [])
            }
            // big page number
            let num = "\(index + 1)"
            let font = UIFont.systemFont(ofSize: 700, weight: .black)
            let attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                        .foregroundColor: UIColor.white.withAlphaComponent(0.9)]
            let s = NSAttributedString(string: num, attributes: attrs)
            let sz = s.size()
            s.draw(at: CGPoint(x: (CGFloat(pageW) - sz.width) / 2,
                               y: (CGFloat(pageH) - sz.height) / 2))
            // fake dialogue lines
            let lineFont = UIFont.systemFont(ofSize: 64, weight: .bold)
            let lineAttrs: [NSAttributedString.Key: Any] = [.font: lineFont,
                                                            .foregroundColor: UIColor.white]
            for row in 0..<4 {
                let t = NSAttributedString(string: "TRANG \(num) — DÒNG \(row + 1)", attributes: lineAttrs)
                let ts = t.size()
                t.draw(at: CGPoint(x: (CGFloat(pageW) - ts.width) / 2,
                                   y: CGFloat(200 + row * 120)))
            }
        }
    }

    static func ensureFixture() throws -> (url: URL, originals: [String: Data]) {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("test.cbz")
        var files: [(String, Data)] = []
        for i in 0..<pageCount {
            autoreleasepool {
                guard let data = makePageImage(index: i).jpegData(compressionQuality: 0.6) else {
                    fatalError("jpeg encode failed page \(i)")
                }
                files.append((String(format: "page_%03d.jpg", i + 1), data))
            }
        }
        try ZipWriter.create(at: url, files: files)
        return (url, Dictionary(uniqueKeysWithValues: files))
    }

    // MARK: Bench

    static func run() -> Verdict {
        var v = Verdict(pass: false, pageCount: 0, expectedPages: pageCount,
                        generateMs: 0, openMs: 0, firstFullDecodeMs: 0,
                        avgFullDecodeMs: 0, maxFullDecodeMs: 0, avgThumbDecodeMs: 0,
                        integrityOK: true, decodeFailures: 0, dimsOK: true,
                        fullDimsSample: "", thumbDimsSample: "",
                        rssDeltaMB: 0, cbzBytes: 0, error: nil)
        do {
            let rss0 = rssBytes()
            let t0 = Date()
            let (url, originals) = try ensureFixture()
            v.generateMs = ms(t0)
            v.cbzBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

            let tOpen = Date()
            let archive = try ZipArchive(url: url)
            v.openMs = ms(tOpen)
            v.pageCount = archive.entries.count

            let names = archive.pageNames
            guard names.count == pageCount else {
                v.error = "page count \(names.count) != \(pageCount)"
                return v
            }

            // 1) read + byte-exact integrity
            var fullTimes: [Int] = []
            var thumbTimes: [Int] = []
            let first = Date()
            var firstDecodeMs = 0

            for (i, name) in names.enumerated() {
                guard let entry = archive.entries.first(where: { $0.name == name }) else {
                    v.integrityOK = false; continue
                }
                let raw: Data
                do { raw = try archive.read(entry) }
                catch { v.integrityOK = false; v.error = "read \(name): \(error)"; continue }
                if raw != originals[name] { v.integrityOK = false; v.error = "bytes differ: \(name)" }

                autoreleasepool {
                    // production path: downsampled decode to display height
                    let tT = Date()
                    if let img = thumbnail(from: raw, maxPixel: Int(Double(1179) * Double(pageH) / Double(pageW))) {
                        if img.width < 100 || img.height < 100 { v.dimsOK = false }
                        if v.thumbDimsSample.isEmpty { v.thumbDimsSample = "\(img.width)x\(img.height)" }
                    } else { v.decodeFailures += 1 }
                    thumbTimes.append(ms(tT))

                    // full decode path (worst case) — CGImageSource can return
                    // LAZY CGImages (dimensions known, pixels not decoded) which
                    // fakes ~0ms; force rasterization by drawing into a bitmap.
                    let tF = Date()
                    if let img = fullImage(from: raw) {
                        if img.width != pageW || img.height != pageH {
                            v.dimsOK = false
                            v.fullDimsSample = "\(img.width)x\(img.height)"
                        }
                        Self.forceDecode(img)
                    } else { v.decodeFailures += 1 }
                    let f = ms(tF)
                    fullTimes.append(f)
                    if i == 0 { firstDecodeMs = f }
                }
            }
            _ = first

            v.firstFullDecodeMs = firstDecodeMs
            v.avgFullDecodeMs = fullTimes.isEmpty ? 0 : fullTimes.reduce(0, +) / fullTimes.count
            v.maxFullDecodeMs = fullTimes.max() ?? 0
            v.avgThumbDecodeMs = thumbTimes.isEmpty ? 0 : thumbTimes.reduce(0, +) / thumbTimes.count
            let rss1 = rssBytes()
            v.rssDeltaMB = Double(rss1 - rss0) / (1024 * 1024)

            v.pass = v.pageCount == pageCount
                && v.integrityOK
                && v.decodeFailures == 0
                && v.dimsOK
                && v.openMs < 500
                && v.firstFullDecodeMs < 500
                && v.avgThumbDecodeMs < 150
        } catch {
            v.error = "\(error)"
        }
        return v
    }

    // MARK: ImageIO helpers

    static func fullImage(from data: Data) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Forces actual pixel rasterization of a (possibly lazy) CGImage.
    static func forceDecode(_ img: CGImage) {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }

    static func thumbnail(from data: Data, maxPixel: Int) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts)
    }

    // MARK: utils

    private static func ms(_ since: Date) -> Int {
        Int(Date().timeIntervalSince(since) * 1000)
    }

    private static func rssBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
