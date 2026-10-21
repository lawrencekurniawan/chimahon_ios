import Foundation
import Vision
import AppKit

// OCR spike: Apple Vision on real nhattruyenqq Vietnamese webtoon pages.
// Usage: swift main.swift [--lang vi-VT|ko-KR] <image.png> [more...]
// Note (spike finding): Vision's recognitionLanguages is effectively
// "first wins" — ko-KR only detects when listed first; Vietnamese diacritics
// get stripped if another language precedes it. Pass exactly one language.

var langs = ["vi-VT"]
var files: [String] = []
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a == "--lang", let v = it.next() { langs = [v] } else { files.append(a) }
}

func printSupportedLanguages() {
    do {
        let langs = try VNRecognizeTextRequest().supportedRecognitionLanguages()
        print("== supported recognition languages ==")
        print(langs.joined(separator: ", "))
        print("vi-VT supported: \(langs.contains("vi-VT"))")
        print("ko-KR supported: \(langs.contains("ko-KR"))")
    } catch {
        print("language query failed: \(error)")
    }
}

struct Line {
    let text: String
    let confidence: Float
    let box: CGRect  // normalized, origin bottom-left (Vision)
}

func ocr(url: URL) throws -> [Line] {
    guard let img = NSImage(contentsOf: url),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "ocr", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot load \(url.path)"])
    }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = langs
    req.minimumTextHeight = 0.005

    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try handler.perform([req])

    var lines: [Line] = []
    for obs in (req.results ?? []) {
        guard let cand = obs.topCandidates(1).first else { continue }
        lines.append(Line(text: cand.string, confidence: cand.confidence, box: obs.boundingBox))
    }
    // reading order: top -> bottom (flip y from Vision's bottom-left origin)
    lines.sort { ($0.box.maxY) > ($1.box.maxY) }
    return lines
}

printSupportedLanguages()

for path in files {
    let url = URL(fileURLWithPath: path)
    print("\n===== \(url.lastPathComponent) =====")
    do {
        let t0 = Date()
        let lines = try ocr(url: url)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("lines: \(lines.count)  time: \(ms)ms")
        for l in lines {
            let pct = Int(l.confidence * 100)
            print(String(format: "  [%3d%%] y=%.3f  %@", pct, l.box.maxY, l.text))
        }
    } catch {
        print("ERROR: \(error)")
    }
}
