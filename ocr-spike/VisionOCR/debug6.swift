import Foundation
import Vision
import AppKit

let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
func run(_ langs: [String]) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = langs
    let h = VNImageRequestHandler(cgImage: cg, options: [:])
    try! h.perform([req])
    let texts = (req.results ?? []).map { $0.topCandidates(1).first?.string ?? "?" }
    print("[\(langs.joined(separator: ","))] n=\(texts.count) :: \(texts.prefix(3).joined(separator: " || "))")
}
for l in CommandLine.arguments.dropFirst(2) {
    // langs passed as one arg split by +
    run(l.split(separator: "+").map(String.init))
}
