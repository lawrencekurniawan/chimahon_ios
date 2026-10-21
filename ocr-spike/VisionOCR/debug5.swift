import Foundation
import Vision
import AppKit

let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }

func run(_ langs: [String], _ label: String) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = langs
    let h = VNImageRequestHandler(cgImage: cg, options: [:])
    do {
        try h.perform([req])
        let rs = req.results ?? []
        let texts = rs.map { $0.topCandidates(1).first?.string ?? "?" }
        print("[\(label)] n=\(rs.count) :: \(texts.joined(separator: " || "))")
    } catch { print("[\(label)] err \(error)") }
}

run(["vi-VT"], "vi only")
run(["ko-KR"], "ko only")
run(["ko-KR", "vi-VT"], "ko,vi")
run(["vi-VT", "ko-KR"], "vi,ko")
run(["ko-KR", "en-US"], "ko,en")
run(["vi-VT", "ko-KR", "en-US"], "vi,ko,en")
run(["en-US", "ko-KR", "vi-VT"], "en,ko,vi")
run(["ko-KR", "en-US", "vi-VT"], "ko,en,vi")
