import SwiftUI

struct ContentView: View {
    @Environment(DictionaryStore.self) private var store
    @State private var query = "食べました"
    @State private var results: [LookupEntry] = []
    @State private var kanji: [KanjiEntryModel] = []

    private let presets = ["食べました", "読んで", "猫", "学生", "本", "勉強"]

    var body: some View {
        NavigationStack {
            List {
                statusSection
                searchSection
                if !results.isEmpty { resultsSection }
                if !kanji.isEmpty { kanjiSection }
            }
            .navigationTitle("Chimahon Spike")
            .task {
                await store.bootstrap()
                run()
            }
        }
    }

    private var statusSection: some View {
        Section("Engine") {
            switch store.importState {
            case .idle:
                Label("Waiting…", systemImage: "hourglass")
            case .importing:
                Label("Importing dictionary…", systemImage: "arrow.down.circle")
                    .foregroundStyle(.blue)
            case let .done(title, terms):
                Label("\(title) — \(terms) terms", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case let .failed(msg):
                Label(msg, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        }
    }

    private var searchSection: some View {
        Section("Lookup") {
            HStack {
                TextField("Japanese word or phrase", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { run() }
                Button(action: run) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.importState == .idle || store.importState == .importing)
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(presets, id: \.self) { p in
                        Button(p) {
                            query = p
                            run()
                        }
                        .buttonStyle(.bordered)
                        .font(.callout)
                    }
                }
            }
        }
    }

    private var resultsSection: some View {
        Section("Results (\(results.count))") {
            ForEach(results) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.expression)
                            .font(.title2.bold())
                        Text(entry.reading)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let freq = entry.frequencies.first {
                            Text(freq)
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                        }
                        if !entry.pitchPositions.isEmpty {
                            Text("↑\(entry.pitchPositions.map(String.init).joined(separator: ","))")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.purple.opacity(0.2), in: Capsule())
                        }
                    }
                    ForEach(entry.glossaries, id: \.self) { g in
                        Text(g)
                            .font(.callout)
                    }
                    if let from = entry.deinflectedFrom {
                        Text("deinflected: \(query) → \(from)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    if !entry.trace.isEmpty {
                        Text(entry.trace.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var kanjiSection: some View {
        Section("Kanji") {
            ForEach(kanji) { k in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(k.character).font(.largeTitle.bold())
                        VStack(alignment: .leading) {
                            Text("on: \(k.onyomi)").font(.caption)
                            Text("kun: \(k.kunyomi)").font(.caption)
                        }
                        Spacer()
                    }
                    ForEach(k.definitions, id: \.self) { Text($0).font(.callout) }
                    Text(k.stats.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func run() {
        results = store.lookup(query)
        kanji = store.kanjiLookup(query)
    }
}
