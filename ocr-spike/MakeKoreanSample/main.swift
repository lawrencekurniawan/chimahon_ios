import AppKit

// Renders a synthetic Korean "speech bubble" style image for OCR testing.
let text = "안녕하세요, 오늘 날씨가 정말 좋네요!\n너희들은 어디로 가고 있어요?"
let size = NSSize(width: 800, height: 400)
let img = NSImage(size: size)
img.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.boldSystemFont(ofSize: 44),
    .foregroundColor: NSColor.black,
]
(text as NSString).draw(
    with: NSRect(x: 40, y: 80, width: 720, height: 260),
    options: [.usesLineFragmentOrigin],
    attributes: attrs)
img.unlockFocus()
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "/Users/lawrencewong/Movies/chimahon_ios/ocr-spike/images/ko_sample.png"))
print("wrote ko_sample.png")
