import SwiftUI
import UIKit

/// Interactive spike reader: webtoon-style vertical LazyVStack over the
/// synthetic test CBZ — pages decode lazily on appearance (production pattern:
/// inflate → ImageIO thumbnail at display size → NSCache).
final class CBZStore: ObservableObject {
    @Published var names: [String] = []
    let archive: ZipArchive?
    let cache = NSCache<NSString, UIImage>()

    init() {
        var url: URL?
        do {
            let fx = try CBZBench.ensureFixture()
            url = fx.url
        } catch {
            url = nil
        }
        if let url {
            archive = try? ZipArchive(url: url)
            names = archive?.pageNames ?? []
        } else {
            archive = nil
        }
    }

    func image(for name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let entry = archive?.entries.first(where: { $0.name == name }),
              let raw = try? archive?.read(entry) else { return nil }
        let cg = CBZBench.thumbnail(from: raw,
                                    maxPixel: Int(Double(1179) * Double(CBZBench.pageH) / Double(CBZBench.pageW)))
        guard let cg else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: name as NSString)
        return img
    }
}

struct ReaderView: View {
    @StateObject private var store = CBZStore()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.names, id: \.self) { name in
                    PageView(name: name, store: store)
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Text("\(store.names.count) pages (CBZ spike)")
                .font(.caption2.monospacedDigit())
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 48)
                .padding(.trailing, 12)
        }
    }
}

struct PageView: View {
    let name: String
    @ObservedObject var store: CBZStore
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.black.frame(height: 300)
                    .overlay(Text(name).font(.caption2).foregroundStyle(.gray))
            }
        }
        .task {
            if image == nil {
                image = store.image(for: name)
            }
        }
    }
}
