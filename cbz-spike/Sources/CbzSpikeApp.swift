import SwiftUI
import Darwin

/// Headless mode: launch with `-RunCBZBench` → prints one `CBZ_VERDICT:{json}`
/// line and exits 0/1. Without the arg: interactive LazyVStack reader UI for
/// manual scroll-smoothness check on the dedicated simulator.
@main
struct CbzSpikeApp: App {
    init() {
        guard ProcessInfo.processInfo.arguments.contains("-RunCBZBench") else { return }
        let verdict = CBZBench.run()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(verdict), let s = String(data: data, encoding: .utf8) {
            print("CBZ_VERDICT:" + s)
        } else {
            print("CBZ_VERDICT:{\"pass\":false,\"error\":\"encode failed\"}")
        }
        exit(verdict.pass ? 0 : 1)
    }

    var body: some Scene {
        WindowGroup { ReaderView() }
    }
}
