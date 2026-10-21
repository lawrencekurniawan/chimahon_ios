import SwiftUI

@main
struct ChimahonSpikeApp: App {
    @State private var store = DictionaryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
