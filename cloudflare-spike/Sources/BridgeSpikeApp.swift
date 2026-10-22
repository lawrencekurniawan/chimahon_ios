import SwiftUI
import Darwin

/// Headless-test entry: launch with
///   -RunBridgeTest [-TargetURL https://…] [-SettleSeconds 12]
/// prints one line `BRIDGE_VERDICT:{json}` and exits 0/1.
/// Without the launch arg it shows a minimal status UI for manual poking.
@main
struct BridgeSpikeApp: App {
    init() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-RunBridgeTest") else { return }
        let target = Self.launchArg("-TargetURL") ?? "https://nhattruyenqq.com/"
        let settle = Double(Self.launchArg("-SettleSeconds") ?? "12") ?? 12
        BridgeTest.run(target: target, settleSeconds: settle) { verdict in
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            if let data = try? enc.encode(verdict), let s = String(data: data, encoding: .utf8) {
                print("BRIDGE_VERDICT:" + s)
            } else {
                print("BRIDGE_VERDICT:{\"pass\":false,\"error\":\"verdict encoding failed\"}")
            }
            exit(verdict.pass ? 0 : 1)
        }
    }

    private static func launchArg(_ key: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: key), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Cloudflare cookie-bridge spike").font(.headline)
                Text("Launch with -RunBridgeTest for the automated verdict.").font(.caption)
            }
        }
    }
}
