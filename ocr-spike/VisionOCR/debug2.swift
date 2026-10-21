import Foundation
import Vision
import AppKit

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../images/ko_sample.png"
guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("load failed"); exit(1)
}
print("cg image: \(cg.width)x\(cg.height) bpc=\(cg.bitsPerComponent) alpha=\(cg.alphaInfo.rawValue) colorSpace=\(cg.colorSpace.map { String($0.name ?? "?") } ?? "nil")")

func run(_ langs: [String], _ label: String) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = langs
    req.minimumTextHeight = "0.005"
    let h = VNImageRequestHandler(cgImage: cg, options: [:])
    do {
        try h.perform([req])
        let rs = req.results ?? []
        print("[\(label)] results=\(rs.count)")
        for r in rs {
            print("   cand=\(r.topCandidates(3).map { "\($0.string)(\($0.confidence))" }.joined(separator: " | "))")
        }
    } catch {
        print("[\(label)] error \(error)")
    }
}

run(["ko-KR"], "ko only")
run(["ko-KR", "en-US"], "ko+en")
run(["en-US"], "en only")
run([], "default")
